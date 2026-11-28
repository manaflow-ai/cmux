#!/usr/bin/env python3
"""Run-scoped R2 artifact transport for GitHub Actions.

The controller verifies the job's GitHub OIDC identity and signs a URL scoped to
its repository and run. cmux can upload, download and list same-run artifacts;
shared input blobs and cross-run reads are not enabled for cmux.

The job needs permissions: id-token: write. Uploads store a gzip tarball with
paths relative to the least common ancestor of INPUT_PATH. Downloads validate
archive paths and reject links before extracting. Standard library only.

Client implementation synchronized from the fleet artifact action at
2758ae95fa44dce02124a37ca4d7ae41400d336c; keep protocol behavior in sync.
"""
from __future__ import annotations

import fnmatch
import glob
import json
import os
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# Every request names this client (the fleet's file hosts refuse Python-urllib's default agent).
USER_AGENT = "hq-r2-artifact"

ENDPOINT = os.environ.get("R2_ARTIFACT_ENDPOINT", "https://gh-events.cmux.com/github/actions-artifact")
AUDIENCE = "cmux-hq-actions-artifact"
ATTEMPTS = 4
# How long a 503 or a refused connection is retried (retrying): a controller handoff's gap, with room. A handoff
# answers 503 for about 18 s, but a restart can take longer: on 2026-11-26 the controller answered 502/503 for more
# than 60 s (03:33:31Z to past 03:34:34Z). Synthetic probe run 45749419308's perf-tabs-handoff upload gave up at the
# old 60 s window, and tabs-keep-speed paged "state could not be read". Waiting is cheap next to a failed job.
HANDOFF_WINDOW = 300.0
# An upload's PUT to its signed URL is idempotent (the same bytes to the same key), so its other 5xx are retried
# for longer: on 2026-11-22 the store answered HTTP 500 for 14 s (all 4 attempts) and a freestyle-runners pass lost
# its demand job. 7 attempts, the waits capped at RETRY_CAP_S, span about 90 s.
UPLOAD_ATTEMPTS = 7
RETRY_CAP_S = 30
# Cloudflare's answers when the request never reached the controller: 521 origin down, 522 and 523 no connection,
# 530 the tunnel not connected (error 1033). 2026-11-25 05:24-05:57Z: three freestyle-runners passes lost their demand
# or vms job to one 530 on a put's presign, which retried nothing (0.4 s from start to failure).
UNREACHED_ORIGIN = (521, 522, 523, 530)


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def note(kind: str, msg: str) -> None:
    print(f"::{kind}::{msg}" if kind else msg, flush=True)


def fail(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    note("error", msg)
    sys.exit(1)


def infra_failure(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    """Report an exhausted artifact-store outage without disguising it as a test failure."""
    note("error title=Artifact store infrastructure failure", msg)
    if output := env("GITHUB_OUTPUT"):
        try:
            with open(output, "a") as fh:
                fh.write("failure_kind=infrastructure\n")
        except OSError:
            pass
    if summary := env("GITHUB_STEP_SUMMARY"):
        try:
            with open(summary, "a") as fh:
                fh.write(f"- **Artifact storage infrastructure failure:** {msg}\n")
        except OSError:
            pass
    sys.exit(1)


def is_infra_error(exc: BaseException) -> bool:
    """Whether a failed store request is an outage rather than a rejected artifact."""
    if isinstance(exc, urllib.error.HTTPError):
        return exc.code >= 500
    return isinstance(exc, (urllib.error.URLError, TimeoutError, ConnectionError, OSError))


def handoff_error(e: BaseException) -> bool:
    """The controller did not take the request: a 503 (it is starting, draining, or between a re-exec and its
    endpoint being up), a 502 (the proxy in front of it never reached it), Cloudflare's own never-reached-the-origin
    answers (UNREACHED_ORIGIN) or a refused connection. Nothing was recorded, so even a put may be sent again."""
    if isinstance(e, urllib.error.HTTPError):
        return e.code in (502, 503) or e.code in UNREACHED_ORIGIN
    if isinstance(e, ConnectionRefusedError):
        return True
    return isinstance(e, urllib.error.URLError) and isinstance(e.reason, ConnectionRefusedError)


def retrying(what: str, fn, others: bool = True, attempts: int = ATTEMPTS):
    """fn() with `attempts` tries on a network error or a 5xx (others=False: none); a 4xx is the answer.

    A 503 or a refused connection is retried for up to HANDOFF_WINDOW seconds: the fleet controller re-execs on
    its sockets every 5 to 25 minutes and its endpoint answered 503 for about 18 s after one (2026-11-22)."""
    attempt = handoffs = 0
    deadline = None
    while True:
        try:
            return fn()
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:  # HTTPError is a URLError
            if handoff_error(e):
                now = time.monotonic()
                deadline = deadline if deadline is not None else now + HANDOFF_WINDOW
                if now >= deadline:
                    raise
                handoffs += 1
                delay = min(2 ** (handoffs - 1), 8, deadline - now)
                note("warning", f"{what}: {e} (the controller is starting or handing off), retrying for up to "
                                f"{HANDOFF_WINDOW:.0f} s")
            else:
                attempt += 1
                if not others or attempt >= attempts or (isinstance(e, urllib.error.HTTPError) and e.code < 500):
                    raise
                delay = min(2 ** attempt, RETRY_CAP_S)
                note("warning", f"{what}: {e}, attempt {attempt} of {attempts}")
        time.sleep(delay)  # backoff between retries of a remote call, not synchronization


def oidc_token() -> str:
    url, bearer = env("ACTIONS_ID_TOKEN_REQUEST_URL"), env("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
    if not url or not bearer:
        fail("no GitHub OIDC token: give this job `permissions: id-token: write` (r2-artifact signs with it)")
    sep = "&" if "?" in url else "?"
    def call():
        req = urllib.request.Request(f"{url}{sep}audience={AUDIENCE}", headers={
            "Authorization": f"Bearer {bearer}", "User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=30) as res:
            return json.load(res)["value"]
    return retrying("OIDC token", call)


def endpoint(token: str, body: dict) -> dict:
    data = json.dumps(body).encode()
    def call():
        req = urllib.request.Request(ENDPOINT, data=data, method="POST", headers={
            "Authorization": f"Bearer {token}", "Content-Type": "application/json", "User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=60) as res:
            return json.load(res)
    try:
        # A put is retried only when the controller did not take it (handoff_error): it records the name when it
        # signs, so a retry after a lost answer would get 409 (a name is written once per run attempt).
        return retrying(f"{body.get('op')} {body.get('name', '')}".strip(), call, others=body.get("op") != "put")
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace").strip()
        raise LookupError(e.code, detail) from None
    except (urllib.error.URLError, OSError) as e:
        raise LookupError(0, str(e)) from None


def globbed(pattern: str, hidden: bool) -> list[str]:
    try:
        return glob.glob(pattern, recursive=True, include_hidden=hidden)
    except TypeError:  # Python before 3.11: hidden names match only a pattern that names them
        return glob.glob(pattern, recursive=True)


def is_hidden(rel: Path) -> bool:
    return any(part.startswith(".") and part not in (".", "..") for part in rel.parts)


def literal_base(pattern: str) -> Path:
    """The directory part of a pattern before its first glob character."""
    parts = Path(pattern).parts
    base = []
    for part in parts:
        if any(c in part for c in "*?["):
            break
        base.append(part)
    if len(base) == len(parts):  # no glob: a file's base is its directory, a directory is its own
        p = Path(*parts) if parts else Path(".")
        return p if p.is_dir() else (p.parent if str(p.parent) else Path("."))
    return Path(*base) if base else Path(".")


def collect(patterns: list[str], hidden: bool) -> tuple[Path, list[Path]]:
    include = [p for p in patterns if not p.startswith("!")]
    exclude = [p[1:] for p in patterns if p.startswith("!")]
    files: dict[str, Path] = {}
    bases = []
    for pattern in include:
        pattern = os.path.expanduser(pattern)
        base = literal_base(pattern)
        bases.append(Path(os.path.abspath(base)))
        matches = globbed(pattern, hidden) if any(c in pattern for c in "*?[") else (
            [pattern] if os.path.exists(pattern) else [])
        for m in matches:
            p = Path(m)
            found = [p] if p.is_file() else [q for q in p.rglob("*") if q.is_file()] if p.is_dir() else []
            for f in found:
                f = Path(os.path.abspath(f))
                b = Path(os.path.abspath(base))
                rel_to_base = f.relative_to(b) if f.is_relative_to(b) else Path(f.name)
                if not hidden and is_hidden(rel_to_base):
                    continue
                files[str(f)] = f
    for pattern in exclude:
        for m in globbed(os.path.expanduser(pattern), True):
            p = Path(os.path.abspath(m))
            for key in [k for k in files if k == str(p) or Path(k).is_relative_to(p)]:
                del files[key]
    if not bases:
        return Path("."), []
    root = Path(os.path.commonpath([str(b) for b in bases]))
    if root.is_file():
        root = root.parent
    return root, sorted(files.values())


def upload() -> None:
    name = env("INPUT_NAME") or "artifact"
    patterns = [line.strip() for line in os.environ.get("INPUT_PATH", "").splitlines() if line.strip()]
    if not patterns:
        fail("no path to upload")
    days_text = env("INPUT_RETENTION_DAYS") or "3"
    if not days_text.isdigit() or not 1 <= int(days_text) <= 14:
        fail(f"retention-days {days_text!r}: the fleet store keeps 1 to 14 days")
    on_empty = env("INPUT_IF_NO_FILES_FOUND") or "warn"
    hidden = env("INPUT_INCLUDE_HIDDEN_FILES").lower() == "true"
    root, files = collect(patterns, hidden)
    if not files:
        msg = f"no files found for artifact {name} at {', '.join(patterns)}"
        if on_empty == "error":
            fail(msg)
        if on_empty != "ignore":
            note("warning", msg + "; nothing uploaded")
        return
    with tempfile.TemporaryDirectory(dir=env("RUNNER_TEMP") or None) as tmp:
        archive = Path(tmp) / "artifact.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for f in files:
                arc = f.relative_to(root) if f.is_relative_to(root) else Path(f.name)
                tar.add(f, arcname=arc.as_posix(), recursive=False)
        size = archive.stat().st_size
        try:
            token = oidc_token()
        except BaseException as e:
            if is_infra_error(e):
                infra_failure(f"could not obtain the OIDC token for artifact {name}: {e}")
            raise
        try:
            out = endpoint(token, {"op": "put", "name": name, "retention_days": int(days_text)})
        except LookupError as e:
            status = e.args[0] if e.args else 0
            msg = f"the fleet store refused artifact {name}: HTTP {e.args[0]} {e.args[1]}"
            if isinstance(status, int) and (status == 0 or status >= 500):
                infra_failure(msg)
            fail(msg)

        def put():
            with open(archive, "rb") as fh:
                req = urllib.request.Request(out["put_url"], data=fh, method="PUT", headers={
                    "Content-Length": str(size), "Content-Type": "application/gzip", "User-Agent": USER_AGENT})
                with urllib.request.urlopen(req, timeout=600) as res:
                    return res.status
        try:
            retrying(f"upload {name}", put, attempts=UPLOAD_ATTEMPTS)
        except (urllib.error.URLError, OSError, TimeoutError, ConnectionError) as e:
            msg = f"upload of artifact {name} to the fleet store failed: {e}"
            if is_infra_error(e):
                infra_failure(msg)
            fail(msg)
    note("", f"uploaded artifact {name}: {len(files)} files, {size} bytes, kept {days_text} days, "
             f"run {env('GITHUB_RUN_ID')} (fleet store {out['key']})")
    # A person reads it from the run's summary, as from the Actions artifact list: a link signed for 6 hours.
    # Later, `artifact.py download` with INPUT_RUN_ID from any job of this repository with id-token: write.
    if summary := env("GITHUB_STEP_SUMMARY"):
        try:
            link = endpoint(token, {"op": "get", "name": name, "ttl_minutes": 360})["get_url"]
            line = f"- Artifact `{name}` ({size} bytes, kept {days_text} days, fleet store): [download]({link}) (link signed for 6 hours)\n"
        except (LookupError, OSError, KeyError):
            line = f"- Artifact `{name}` ({size} bytes, kept {days_text} days): fleet store key `{out['key']}`\n"
        with open(summary, "a") as fh:
            fh.write(line)


def extract(get_url: str, dest: Path, name: str, missing_ok: bool = False) -> int | None:
    with tempfile.TemporaryDirectory(dir=env("RUNNER_TEMP") or None) as tmp:
        archive = Path(tmp) / "artifact.tar.gz"

        def get():
            req = urllib.request.Request(get_url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=600) as res, open(archive, "wb") as fh:
                while chunk := res.read(1 << 20):
                    fh.write(chunk)
        try:
            retrying(f"download {name}", get)
        except urllib.error.HTTPError as e:
            if e.code == 404 and missing_ok:
                note("warning", f"artifact {name} was signed for but never uploaded; skipped")
                return None
            if e.code == 404:
                fail(f"artifact {name} was signed for but never uploaded (the store has no object)")
            raise
        dest.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive, "r:gz") as tar:
            members = tar.getmembers()
            for m in members:
                target = (dest / m.name).resolve()
                if not (m.isfile() or m.isdir()) or not target.is_relative_to(dest.resolve()):
                    fail(f"artifact {name}: refusing archive entry {m.name!r}")
            tar.extractall(dest, filter="data") if hasattr(tarfile, "data_filter") else tar.extractall(dest)
            return sum(1 for m in members if m.isfile())


def download() -> None:
    name, pattern = env("INPUT_NAME"), env("INPUT_PATTERN")
    dest = Path(os.path.expanduser(env("INPUT_PATH") or "."))
    run_text = env("INPUT_RUN_ID") or env("GITHUB_RUN_ID")
    if not run_text.isdigit():
        fail(f"run-id {run_text!r} is not a run id")
    run_id = int(run_text)
    merge = env("INPUT_MERGE_MULTIPLE").lower() == "true"
    token = oidc_token()
    if name:
        try:
            out = endpoint(token, {"op": "get", "name": name, "run_id": run_id})
        except LookupError as e:
            fail(f"artifact {name} of run {run_id}: HTTP {e.args[0]} {e.args[1]}")
        n = extract(out["get_url"], dest, name)
        note("", f"downloaded artifact {name} of run {run_id}: {n} files into {dest}")
    else:
        try:
            names = endpoint(token, {"op": "list", "run_id": run_id})["names"]
        except LookupError as e:
            fail(f"artifacts of run {run_id}: HTTP {e.args[0]} {e.args[1]}")
        names = [n for n in names if not pattern or fnmatch.fnmatchcase(n, pattern)]
        if not names:
            note("warning", f"no artifacts of run {run_id} match {pattern or '*'}")
        for n in names:
            # As download-artifact by pattern: what a job never uploaded is not there, and the rest still come.
            try:
                out = endpoint(token, {"op": "get", "name": n, "run_id": run_id})
            except LookupError as e:
                note("warning", f"artifact {n} of run {run_id}: HTTP {e.args[0]} {e.args[1]}; skipped")
                continue
            got = extract(out["get_url"], dest if merge else dest / n, n, missing_ok=True)
            if got is not None:
                note("", f"downloaded artifact {n} of run {run_id}: {got} files")
    if out_file := env("GITHUB_OUTPUT"):
        with open(out_file, "a") as fh:
            fh.write(f"download-path={dest.resolve()}\n")


def presign() -> None:
    args = sys.argv[2:]
    if len(args) not in (2, 3) or args[0] not in ("put", "get") or (args[0] == "put") != (len(args) == 3):
        fail("usage: artifact.py presign put NAME RETENTION_DAYS | presign get NAME")
    op, name = args[0], args[1]
    body = {"op": op, "name": name, "ttl_minutes": int(env("INPUT_TTL_MINUTES") or "360")}
    # A get may name another run of this repository (INPUT_RUN_ID), as download does: the pack mirror's guests read
    # the newest producer run's packs (tools/freestyle-workflow/fsr_pack.py sources).
    if op == "get" and env("INPUT_RUN_ID"):
        if not env("INPUT_RUN_ID").isdigit():
            fail(f"run id {env('INPUT_RUN_ID')!r}: not a number")
        body["run_id"] = int(env("INPUT_RUN_ID"))
    if op == "put":
        if not args[2].isdigit() or not 1 <= int(args[2]) <= 14:
            fail(f"retention-days {args[2]!r}: the fleet store keeps 1 to 14 days")
        body["retention_days"] = int(args[2])
    try:
        out = endpoint(oidc_token(), body)
    except LookupError as e:
        fail(f"{op} {name}: HTTP {e.args[0]} {e.args[1]}")
    print(out["put_url" if op == "put" else "get_url"])


def blob_get() -> None:
    args = sys.argv[2:]
    if len(args) != 1 or len(args[0]) != 64 or any(c not in "0123456789abcdef" for c in args[0]):
        fail("usage: artifact.py blob-get SHA256 (64 lowercase hex)")
    body = {"op": "blob-get", "sha256": args[0], "ttl_minutes": int(env("INPUT_TTL_MINUTES") or "60")}
    try:
        out = endpoint(oidc_token(), body)
    except LookupError as e:
        if e.args[0] == 404:
            note("warning", f"the fleet store has no blob sha256:{args[0]}")
            sys.exit(3)
        fail(f"blob-get sha256:{args[0]}: HTTP {e.args[0]} {e.args[1]}")
    print(out["get_url"])


def blob_put() -> None:
    import hashlib
    args = sys.argv[2:]
    if len(args) != 1 or not Path(args[0]).is_file():
        fail("usage: artifact.py blob-put FILE")
    path = Path(args[0])
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        while chunk := fh.read(1 << 20):
            digest.update(chunk)
    hexdigest, size = digest.hexdigest(), path.stat().st_size
    token = oidc_token()
    try:
        out = endpoint(token, {"op": "blob-put", "sha256": hexdigest, "size": size})
    except LookupError as e:
        fail(f"blob-put sha256:{hexdigest}: HTTP {e.args[0]} {e.args[1]}")

    def put():
        with open(path, "rb") as fh:
            req = urllib.request.Request(out["put_url"], data=fh, method="PUT", headers={
                **out.get("headers", {}), "Content-Length": str(size), "User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=600) as res:
                return res.status
    try:
        retrying(f"blob-put sha256:{hexdigest}", put, attempts=UPLOAD_ATTEMPTS)
    except (urllib.error.URLError, OSError) as e:
        fail(f"blob-put sha256:{hexdigest}: {e}")
    note("", f"put {path.name} as {out['key']} ({size} bytes)")


if __name__ == "__main__":
    {"upload": upload, "download": download, "presign": presign, "blob-get": blob_get, "blob-put": blob_put}.get(
        sys.argv[1] if len(sys.argv) > 1 else "", lambda: fail(
        "usage: artifact.py upload|download|presign|blob-get|blob-put"))()
