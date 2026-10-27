#!/usr/bin/env python3
"""Write the seed corpus of each diff sidecar fuzz target.

Seeds are the requests, patches and manifests the sidecar's own tests send
(src/server.rs, src/server/file_contents_tests.rs, tests/server_integration.rs),
built here so the fuzzer starts past the JSON shapes and header prefixes. Each
seed is named by its SHA-1, as libFuzzer names corpus files, so seeding twice
adds nothing. scripts/cmux-next/rust-fuzz.sh --fuzz-dir Native/DiffSidecar/fuzz
runs it with the same arguments as cmux-tui/fuzz/seeds.py.

Usage: seeds.py --repo REPO_ROOT --out CORPUS_ROOT [TARGET ...]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Callable, Iterable

TOKEN = "0123456789abcdef"


def request(method: str, params: dict | None = None, *, version: int = 1) -> bytes:
    body: dict = {"id": method, "version": version, "method": method}
    if params is not None:
        body["params"] = params
    return json.dumps(body).encode()


def rpc_requests(_repo: Path) -> Iterable[bytes]:
    repo_root = "/tmp/repo"
    yield request("protocolHandshake")
    yield request("protocolHandshake", version=2)
    for source in (
        {"kind": "patch", "path": "/viewer.patch"},
        {"kind": "unstaged", "repoRoot": repo_root},
        {"kind": "staged", "repoRoot": repo_root},
        {"kind": "branch", "repoRoot": repo_root},
        {"kind": "branch", "repoRoot": repo_root, "baseRef": "origin/main"},
    ):
        yield request("sessionOpen", {
            "source": source,
            "capabilityToken": TOKEN,
            "sessionId": "6f1c0d5e-2a43-4b8e-9d0f-1a2b3c4d5e6f",
            "ignoreWhitespace": True,
        })
    yield request("sessionClose", {"sessionId": "s", "capabilityToken": TOKEN})
    yield request("branchList", {"repoRoot": repo_root, "capabilityToken": TOKEN,
                                 "selectedBase": None})
    yield request("branchChange", {"groupId": "g", "repoRoot": repo_root,
                                   "baseRef": "main", "capabilityToken": TOKEN,
                                   "ignoreWhitespace": False})
    yield request("fileContents", {"sessionId": "s", "capabilityToken": TOKEN,
                                   "path": "src/a b.rs", "previousPath": "src/old.rs",
                                   "encoding": "base64"})
    yield b"{"
    yield b'{"id":"x","version":1,"method":"sessionOpen","params":{}}'


def patch_seed(wanted: list[str], patch: str) -> bytes:
    return "\0".join(wanted).encode() + b"\n" + patch.encode()


def patch_names(_repo: Path) -> Iterable[bytes]:
    patch = "".join((
        "diff --git a/one.txt b/one.txt\n",
        "--- a/one.txt\n",
        "+++ b/one.txt\n",
        "@@ -1 +1 @@\n",
        "-diff --git a/hidden.txt b/hidden.txt\n",
        "+one\n",
        "diff --git a/old name.txt b/new name.txt\n",
        "similarity index 90%\n",
        "rename from old name.txt\n",
        "rename to new name.txt\n",
        "diff --git a/image.png b/image.png\n",
        "GIT binary patch\n",
        "literal 1\n",
        "diff --git \"a/sp\\303\\251cial.txt\" \"b/sp\\303\\251cial.txt\"\n",
        "diff --git \"a/q\\\"x\" b/q\"x\n",
        "copy from a.txt\n",
        "copy to b.txt\n",
        "--- \"a/t\\tab\"\n",
        "+++ /dev/null\n",
    ))
    yield patch_seed(["one.txt"], patch)
    yield patch_seed(["new name.txt", "old name.txt", "image.png", "spécial.txt"], patch)
    yield patch_seed(["hidden.txt"], patch)
    yield patch_seed(["a/éé b/é"], "diff --git a/éé b/é\n")
    yield patch_seed(["x"], "diff --git \"a/x\\\n")


def manifest(_repo: Path) -> Iterable[bytes]:
    files = [
        {"request_path": "/viewer.html", "file_path": "/tmp/root/viewer.html",
         "mime_type": "text/html", "remote_url": None},
        {"request_path": "/assets/main.mjs", "file_path": "/tmp/root/main.mjs",
         "mime_type": "text/javascript", "remote_url": None},
        {"request_path": "/remote.patch", "file_path": "",
         "mime_type": "text/x-diff", "remote_url": "https://example.invalid/a.patch"},
    ]
    yield json.dumps({"token": TOKEN, "files": files}).encode()
    yield json.dumps({"token": TOKEN, "files": [files[0], files[0]]}).encode()
    yield json.dumps({"token": TOKEN, "files": [
        {**files[0], "request_path": "/../secret.html"}]}).encode()
    yield f"/{TOKEN}/viewer.patch".encode()
    yield f"//{TOKEN}/a/./b.patch".encode()


TARGETS: dict[str, Callable[[Path], Iterable[bytes]]] = {
    "diff_rpc_request": rpc_requests,
    "diff_patch_names": patch_names,
    "diff_manifest": manifest,
}


def write_seeds(repo: Path, out: Path, target: str) -> int:
    directory = out / target
    directory.mkdir(parents=True, exist_ok=True)
    written = 0
    for seed in TARGETS[target](repo) if target in TARGETS else ():
        path = directory / hashlib.sha1(seed).hexdigest()
        if not path.exists():
            path.write_bytes(seed)
            written += 1
    return written


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--list", action="store_true", help="print the seeded targets")
    parser.add_argument("targets", nargs="*")
    args = parser.parse_args(argv)
    if args.list:
        print("\n".join(TARGETS))
        return 0
    for target in args.targets or list(TARGETS):
        if target in TARGETS:
            print(f"{target}: {write_seeds(args.repo, args.out, target)} new seeds")
        else:
            print(f"{target}: no seeds", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
