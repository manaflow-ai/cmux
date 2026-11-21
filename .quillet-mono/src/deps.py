"""Fetches the fonttools and brotli wheels from PyPI (sha256-checked) into a dir: the Linux pool has no pip/venv/uv."""
import hashlib, io, json, platform, sys, urllib.request, zipfile

dest = sys.argv[1]
tag = f"cp{sys.version_info.major}{sys.version_info.minor}"
arch = platform.machine()
for pkg, ver, want in [("fonttools", "4.60.1", "py3-none-any"), ("brotli", "1.1.0", tag)]:
    meta = json.load(urllib.request.urlopen(f"https://pypi.org/pypi/{pkg}/{ver}/json"))
    files = [u for u in meta["urls"] if u["filename"].endswith(".whl") and want in u["filename"]]
    if pkg == "brotli":
        files = [u for u in files if "manylinux" in u["filename"] and arch in u["filename"]]
    f = files[0]
    data = urllib.request.urlopen(f["url"]).read()
    assert hashlib.sha256(data).hexdigest() == f["digests"]["sha256"], f["filename"]
    zipfile.ZipFile(io.BytesIO(data)).extractall(dest)
    print("deps:", f["filename"])
