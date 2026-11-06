#!/usr/bin/env bash
set -euo pipefail
APK_PATH="${1:?Usage: build-from-apk.sh Mola-4.2.apk}"
OUT="${2:-Mola-4.2-repacked.aab}"
WORK="$(mktemp -d)"
echo "Working directory: $WORK"
curl -fsSL "https://github.com/iBotPeaches/Apktool/releases/download/v2.12.1/apktool_2.12.1.jar" -o "$WORK/apktool.jar"
curl -fsSL "https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar" -o "$WORK/bundletool.jar"

# Google Maven's AAPT2 produces the proto resources required by bundletool.
python3 - "$WORK" <<'PY'
import urllib.request, xml.etree.ElementTree as ET, sys, pathlib, zipfile, os
w=pathlib.Path(sys.argv[1])
base='https://dl.google.com/dl/android/maven2/com/android/tools/build/aapt2/'
root=ET.fromstring(urllib.request.urlopen(base+'maven-metadata.xml').read())
versions=[v.text for v in root.findall('.//version') if v.text]
versions=[v for v in versions if v.startswith('9.2.1-')] or versions
version=versions[-1]
print('AAPT2 version:',version)
url=f'{base}{version}/aapt2-{version}-linux.jar'
jar=w/'aapt2.jar'
jar.write_bytes(urllib.request.urlopen(url).read())
with zipfile.ZipFile(jar) as z:
    name=next(n for n in z.namelist() if n=='aapt2')
    (w/'aapt2').write_bytes(z.read(name))
(w/'aapt2').chmod(0o755)
PY
java -jar "$WORK/apktool.jar" d -s -f "$APK_PATH" -o "$WORK/decoded"
python3 - "$WORK/decoded" <<'PY'
from pathlib import Path
import sys,re
root=Path(sys.argv[1])
for p in root.rglob('*.xml'):
    try:
        s=p.read_text('utf-8')
        t=re.sub(r'\$([A-Za-z][A-Za-z0-9_]*)',r'generated_\1',s)
        if t!=s: p.write_text(t,'utf-8')
    except UnicodeDecodeError: pass
for p in sorted((root/'res').rglob('*'),key=lambda x:len(x.parts),reverse=True):
    if '$' in p.name:
        p.rename(p.with_name(p.name.replace('$','generated_')))
PY
# Decompiled strings may contain multiple non-positional printf placeholders.
# Prevent AAPT2's formatting validator from rejecting recovered string resources.
python3 - "$WORK/decoded/res" <<'PY'
from pathlib import Path
import sys,re
root=Path(sys.argv[1])
count=0
for p in root.glob('values*/strings.xml'):
    s=p.read_text('utf-8')
    def fix(m):
        global count
        tag=m.group(0)
        if 'formatted=' not in tag:
            count+=1
            return tag[:-1]+' formatted="false">'
        return tag
    s=re.sub(r'<string\b[^>]*>',fix,s)
    p.write_text(s,'utf-8')
print('Disabled formatting validation on',count,'string entries')
PY
mkdir -p "$WORK/base/manifest" "$WORK/base/dex"
"$WORK/aapt2" compile --dir "$WORK/decoded/res" -o "$WORK/compiled.zip"
"$WORK/aapt2" link --proto-format -o "$WORK/linked.zip" \
    -I "$ANDROID_HOME/platforms/android-36/android.jar" \
    --manifest "$WORK/decoded/AndroidManifest.xml" \
    --rename-manifest-package com.nexvory.mola \
    --min-sdk-version 28 --target-sdk-version 36 \
    --version-code 324 --version-name 4.2 \
    -R "$WORK/compiled.zip" --auto-add-overlay
unzip -q "$WORK/linked.zip" -d "$WORK/base"
mv "$WORK/base/AndroidManifest.xml" "$WORK/base/manifest/AndroidManifest.xml"
for dex in classes*.dex; do :; done
python3 - "$APK_PATH" "$WORK/base/dex" <<'PY'
import zipfile,sys,pathlib
with zipfile.ZipFile(sys.argv[1]) as z:
  for name in z.namelist():
    if name.startswith('classes') and name.endswith('.dex') and '/' not in name:
      pathlib.Path(sys.argv[2],name).write_bytes(z.read(name))
PY
for d in assets lib; do
  if [ -d "$WORK/decoded/$d" ]; then cp -a "$WORK/decoded/$d" "$WORK/base/"; fi
done
(cd "$WORK/base" && zip -q -r "$WORK/module.zip" .)
java -jar "$WORK/bundletool.jar" build-bundle --modules="$WORK/module.zip" --output="$OUT"
java -jar "$WORK/bundletool.jar" validate --bundle="$OUT"
echo "Created experimental AAB: $OUT"
