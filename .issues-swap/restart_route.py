#!/usr/bin/env python3
"""ISSUES DAEMON-SWAP (scratch, not for merge): the real VM route.

An OLD daemon runs with the VM's exact argv (session main, default socket
under XDG_RUNTIME_DIR, default state dir) in an isolated HOME. Shells,
a 20 Hz ticker and an output flood run in it. Then the NEW CLI runs
`--session main daemon restart` (the proposed fix). Checks: same shells,
host pids, scrollback, echo, the pause each writer saw. Then the rollback:
OLD `server stop` + `server ensure`, the same checks.
"""
import importlib.util, json, os, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("swap", repo / "scripts/cmux-next/daemon-swap-check.py")
swap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(swap)
data, wait_until, shell_pid, host_pids, now = swap.data, swap.wait_until, swap.shell_pid, swap.host_pids, swap.now


def gaps(path: Path, start: float, end: float) -> dict:
    try:
        ts = [float(x) for x in path.read_text().split() if x]
    except OSError:
        return {"error": "no file"}
    window = [t for t in ts if start - 2 <= t <= end + 2]
    biggest = max((b - a for a, b in zip(window, window[1:])), default=None)
    return {"max_gap_secs": round(biggest, 3) if biggest is not None else None,
            "ticks_in_window": len(window), "last_tick_after_end": bool(ts) and ts[-1] > end}


def main() -> int:
    root = Path(tempfile.mkdtemp(prefix="cmux-restart-route-", dir="/tmp"))
    bindir = root / "bin"
    bindir.mkdir()
    old, new = bindir / "old" / "cmux", bindir / "new" / "cmux"
    for src, dst in ((sys.argv[1], old), (sys.argv[2], new)):
        dst.parent.mkdir()
        shutil.copy2(src, dst)
    home, run, tmp = root / "home", root / "run", root / "tmp"
    for d in (home, run, tmp):
        d.mkdir(mode=0o700)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("ACPMUX_", "CMUX_", "XDG_")) and k not in ("ENV", "BASH_ENV")}
    env.update(HOME=str(home), XDG_RUNTIME_DIR=str(run), TMPDIR=str(tmp),
               SHELL=shutil.which("bash") or "/bin/sh", TERM="xterm-256color")
    sockdir = run / f"cmux-tui-{os.getuid()}"
    sock = sockdir / "main.sock"
    report: dict = {"root": str(root)}
    log = open(root / "old-daemon.log", "wb")
    proc = subprocess.Popen(
        [str(old), "--headless", "--session", "main", "--socket", str(sock), "--term", "xterm-ghostty",
         "--owner-host-fg", "#fdfff1", "--owner-host-bg", "#272822"],
        env=env, cwd=home, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    terms = []
    try:
        wait_until("old daemon", now() + 30, lambda: data(sock, {"cmd": "identify"}))
        before = data(sock, {"cmd": "identify"})
        report["old_identify"] = {k: before.get(k) for k in ("pid", "build_commit", "version", "session", "daemon_handoff")}
        argvs = [["bash"], ["bash"], ["bash"],
                 ["bash", "-c", f"while :; do printf 'tick %s\\n' \"$(date +%s.%N)\"; date +%s.%N >> {root}/ticks; sleep 0.05; done"],
                 ["bash", "-c", f"while :; do seq 1 5000; date +%s.%N >> {root}/flood; done"]]
        for i, argv in enumerate(argvs):
            c = data(sock, {"cmd": "run", "argv": argv, "new_workspace": True})
            terms.append({"i": i, "surface": c["surface"], "terminal_id": c["terminal_id"],
                          "incarnation": c["terminal_incarnation"], "interactive": i < 3,
                          "marker": f"route-before-{os.getpid()}-{i}"})
        for t in terms[:3]:
            data(sock, {"cmd": "send", "surface": t["surface"], "text": f"echo {t['marker']}; echo PID$((0))=$$\n"})
        for t in terms[:3]:
            s = wait_until("marker", now() + 20, lambda t=t: (s := data(sock, {"cmd": "read-screen", "surface": t["surface"]}).get("text") or "") and t["marker"] in s and shell_pid(s, "PID0") and s)
            t["shell_pid"] = shell_pid(s, "PID0")
        hosts = wait_until("host records", now() + 20, lambda: (h := host_pids(root)) and len(h) >= len(terms) and h)
        time.sleep(2)  # writers run before the swap

        def swap_step(name: str, commands: list[list[str]], tag: str) -> dict:
            t0w, t0 = time.time(), now()
            outs = []
            for cmd in commands:
                cp = subprocess.run([str(c) for c in cmd], env=env, cwd=home, capture_output=True, text=True, timeout=180)
                outs.append({"cmd": " ".join(str(c) for c in cmd[1:]), "exit": cp.returncode,
                             "out": (cp.stdout + cp.stderr)[-1500:], "secs": round(now() - t0, 3)})
                if cp.returncode != 0:
                    break
            ident = wait_until("daemon after " + name, now() + 60, lambda: data(sock, {"cmd": "identify"}))
            answers = now() - t0
            checks = []
            for t in terms:
                try:
                    r = wait_until("adopted", now() + 60, lambda t=t: (r := data(sock, {"cmd": "resolve-terminal", "terminal_id": t["terminal_id"]})) and r.get("lifecycle") == "running" and r)
                    c = {"i": t["i"], "running": True, "same_incarnation": r.get("terminal_incarnation") == t["incarnation"]}
                    surf = r.get("surface") or t["surface"]
                    t["surface"] = surf
                    if t["interactive"]:
                        c["scrollback_kept"] = t["marker"] in (data(sock, {"cmd": "read-screen", "surface": surf}).get("text") or "")
                        data(sock, {"cmd": "send", "surface": surf, "text": f"echo {tag}=$$\n"})
                        s = wait_until("echo", now() + 30, lambda: (s := data(sock, {"cmd": "read-screen", "surface": surf}).get("text") or "") and shell_pid(s, tag) and s)
                        c["same_shell_pid"] = shell_pid(s, tag) == t["shell_pid"]
                    checks.append(c)
                except Exception as e:  # noqa: BLE001
                    checks.append({"i": t["i"], "running": False, "error": f"{type(e).__name__}: {e}"})
            done, donew = now() - t0, time.time()
            time.sleep(1.5)
            after_hosts = host_pids(root)
            return {"step": name, "commands": outs, "daemon_answers_secs": round(answers, 3),
                    "all_checks_secs": round(done, 3),
                    "identify": {k: ident.get(k) for k in ("pid", "build_commit", "version", "session")},
                    "same_host_pids": all(after_hosts.get(k) == v for k, v in hosts.items()),
                    "hosts_alive": all(swap.pid_alive(p) for p in hosts.values()),
                    "terminals": checks,
                    "ticker": gaps(root / "ticks", t0w, donew), "flood": gaps(root / "flood", t0w, donew),
                    "passed": all(o["exit"] == 0 for o in outs) and all(c.get("running") and c.get("same_incarnation", False) and c.get("scrollback_kept", True) and c.get("same_shell_pid", True) for c in checks)}

        fwd = swap_step("forward: new --session main daemon restart", [[new, "--session", "main", "daemon", "restart"]], "PID1")
        fwd["new_daemon"] = fwd["identify"]["pid"] != before.get("pid")
        fwd["passed"] = fwd["passed"] and fwd["new_daemon"] and fwd["same_host_pids"]
        report["forward"] = fwd
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        report["old_daemon_exited"] = proc.poll() is not None
        caps = data(sock, {"cmd": "identify"}).get("capabilities") or []
        report["new_capabilities_count"] = len(caps)
        report["new_capabilities_agent"] = [c for c in caps if "agent" in str(c)]
        back = swap_step("rollback: old server stop + old server ensure",
                         [[old, "--session", "main", "server", "stop"], [old, "--session", "main", "server", "ensure"]], "PID2")
        back["old_build_again"] = (back["identify"].get("build_commit") or "") == (before.get("build_commit") or "x")
        back["passed"] = back["passed"] and back["old_build_again"] and back["same_host_pids"]
        report["rollback"] = back
    except Exception as e:  # noqa: BLE001
        report["error"] = f"{type(e).__name__}: {e}"
    finally:
        # Cleanup: only processes whose executable is under this run's root.
        for path in Path("/proc").iterdir():
            if path.name.isdigit():
                try:
                    if os.readlink(path / "exe").startswith(str(root)):
                        os.kill(int(path.name), signal.SIGKILL)
                except OSError:
                    pass
        try:
            report["old_daemon_log_tail"] = (root / "old-daemon.log").read_text(errors="replace")[-1500:]
        except OSError:
            pass
    report["passed"] = bool(report.get("forward", {}).get("passed")) and bool(report.get("rollback", {}).get("passed"))
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
