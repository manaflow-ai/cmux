"""One-off (not committed): the old python checkers over the new crate's row tables."""
import importlib.util, pathlib, sys, tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROWS = HERE.parent.parent / "cmux-source-scan/src"
PRELUDE = "struct Cached { at: u64 }\ntype Leaf = fn(u8);\ntrait Callback { type Hook; }\n"


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / name)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


def rows(path):
    out = []
    for line in path.read_text().splitlines():
        if line.startswith("=== "):
            args, title = line[4:].split(" :: ", 1); out.append([args, title, ""])
        elif out:
            out[-1][2] += line + "\n"
    return out


def hooks(check, label):
    bad = 0
    for args, title, src in rows(ROWS / "test_hooks_rows.txt"):
        parts = args.split(" ", 3)
        kind = parts[0]
        file = "chain.rs" if kind == "chain" else parts[1]
        text = PRELUDE + src if kind == "chain" else src
        rel = "cmux-tui/crates/acpmux/src/" + file
        with tempfile.TemporaryDirectory() as tmp:
            p = pathlib.Path(tmp) / "x.rs"; p.write_text(text)
            found = check.judge_file(p, rel)
        at = f"{rel}:{parts[2]}:" if len(parts) > 2 else ""
        words = parts[3] if len(parts) > 3 else ""
        ok = {"passes": not found, "chain": (bool(found) == (parts[1] == "refused")),
              "refused": any(f.startswith(at) and words in f for f in found),
              "clear": not any(f.startswith(at) for f in found)}[kind]
        if not ok:
            bad += 1; print(f"{label} FAIL: {title} ({args})")
    print(f"{label}: {bad} rows fail")


TPRELUDE = "use std::time::{Duration, Instant};\n\nfn helper() -> Duration {\n    let t = Instant::now();\n    t.elapsed()\n}\n"


def trows(path):
    out = []
    section = "rust"
    for line in path.read_text().splitlines():
        if line.startswith("=== "):
            v, what, kind, title = line[4:].split(" :: ", 3)
            out.append(dict(v=v, what=what, kind=kind, title=title, rust="", bare=False, nextest=None))
            section = "rust"
            continue
        if not out:
            continue
        r = out[-1]
        if line == "--- rust":
            section = "rust"
        elif line == "--- bare":
            section = "rust"; r["bare"] = True
        elif line == "--- nextest":
            section = "nextest"; r["nextest"] = r["nextest"] or ""
        elif section == "nextest":
            r["nextest"] = (r["nextest"] or "") + line + "\n"
        else:
            r["rust"] += line + "\n"
    return out


def run_check(script, checkout, *paths):
    import subprocess
    return subprocess.run([sys.executable, "-I", str(HERE / script), str(checkout), *map(str, paths)],
                          capture_output=True, text=True, timeout=120)


def timing(script, label):
    bad = 0
    rows = trows(ROWS / "timing_ratio_rows.txt")
    for r in rows:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            crate = root / "cmux-tui/crates/demo"
            (crate / "tests").mkdir(parents=True); (crate / "src").mkdir()
            (crate / "Cargo.toml").write_text('[package]\nname = "demo"\nversion = "0.1.0"\n')
            (crate / "src/lib.rs").write_text("pub fn work() {}\n")
            (crate / "tests/timing.rs").write_text(r["rust"] if r["bare"] else TPRELUDE + r["rust"])
            if r["nextest"] is not None:
                (root / "cmux-tui/.config").mkdir(parents=True)
                (root / "cmux-tui/.config/nextest.toml").write_text(r["nextest"])
            out = run_check(script, root)
        lines = out.stdout.splitlines()
        if r["v"] == "flagged":
            hits = [l for l in lines if r["what"] in l]
            ok = out.returncode == 1 and hits and (r["kind"] == "-" or r["kind"] in hits[0])
        elif r["v"] == "clean":
            ok = out.returncode == 0 and r["what"] not in out.stdout
        else:
            want = {n for n in r["what"].split(",") if n and n != "-"}
            got = {l.split("`")[1] for l in lines if "`" in l}
            ok = got == want
        if not ok:
            bad += 1
            print(f"{label} FAIL: {r['title']} ({r['v']} `{r['what']}`): rc={out.returncode} {out.stdout.strip()[:300]!r} {out.stderr.strip()[-200:]!r}")
    # hq#9512 F4: no scan is not a clean scan.
    with tempfile.TemporaryDirectory() as tmp:
        t = pathlib.Path(tmp)
        for what, args in (("no cmux-tui/crates", (t,)), ("a missing root", (t, t / "no-such-dir")),
                           ("a missing checkout", (t / "no-such-checkout",))):
            if run_check(script, *args).returncode == 0:
                bad += 1; print(f"{label} FAIL: F4 {what} exits 0")
        (t / "cmux-tui/crates/demo").mkdir(parents=True)
        if run_check(script, t).returncode == 0:
            bad += 1; print(f"{label} FAIL: F4 an empty scan root exits 0")
    print(f"{label}: {bad} of {len(rows) + 4} timing rows fail")


hooks(load("base-check.py"), "check-test-hooks.py at feat-cmux-next (#41383)")
hooks(load("check-test-hooks.py"), "check-test-hooks.py at 8545a9d0 (#41427)")
timing("timing-check.py", "rust-timing-ratio/check.py at hq 3407e310 (#9478)")
timing("timing-check-9512.py", "rust-timing-ratio/check.py at hq 3d97da8c (#9512)")
