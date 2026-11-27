use super::*;

/// The status of a real child that ends as `script` makes it.
fn ended(script: &str) -> std::process::ExitStatus {
    cmux_process::Command::new("sh")
        .args(["-c", script])
        .stdin(cmux_process::Stdio::null())
        .status()
        .unwrap()
}

/// The restart child killed by the stop it issued (signal 15) handed over; one that exited
/// non-zero or died of another signal did not.
#[test]
fn a_restart_child_killed_by_sigterm_handed_over() {
    let restart = "systemctl --user restart --no-block acpmux.service";
    assert_eq!(restart_outcome(restart, ended("kill -TERM $$")), Ok(()));
    assert_eq!(restart_outcome(restart, ended("exit 0")), Ok(()));
    let failed = restart_outcome(restart, ended("exit 5")).unwrap_err();
    assert!(failed.starts_with(restart) && failed.contains('5'), "{failed}");
    let killed = restart_outcome(restart, ended("kill -KILL $$")).unwrap_err();
    assert!(killed.contains("signal: 9"), "{killed}");
    let hup = restart_outcome(restart, ended("kill -HUP $$"));
    assert!(hup.is_err(), "only the stop's own SIGTERM counts");
}

/// Before/after over one harness (cmuxterm-hq #19255 section 2: 33 of 33 handovers logged
/// "did not take over"): N restart children that die of SIGTERM, read as the old check did
/// (`status.success()`) and as `restart_outcome` does.
#[test]
fn handover_sigterm_before_and_after() {
    const N: usize = 8;
    let statuses: Vec<_> = (0..N).map(|_| ended("kill -TERM $$")).collect();
    let before = statuses.iter().filter(|s| !s.success()).count();
    let after = statuses.iter().filter(|s| restart_outcome("systemctl", **s).is_err()).count();
    eprintln!("handover-bench: {N} handovers, 'did not take over' before={before} after={after}");
    assert_eq!((before, after), (N, 0));
}

#[test]
fn the_take_over_daemon_writes_to_the_daemon_log() {
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("daemon.log");
    std::fs::write(&log, "before the update\n").unwrap();
    let (stdout, stderr) = successor_output(&log);
    let status = cmux_process::Command::new("sh")
        .args(["-c", "echo out; echo err >&2"])
        .stdin(cmux_process::Stdio::null())
        .stdout(stdout)
        .stderr(stderr)
        .status()
        .unwrap();
    assert!(status.success());
    assert_eq!(std::fs::read_to_string(&log).unwrap(), "before the update\nout\nerr\n");
}

#[test]
fn the_successor_gets_this_daemons_flags_but_not_its_fds() {
    let args: Vec<String> = [
        "acp",
        "daemon",
        "run",
        "--ready-fd",
        "3",
        "--memory",
        "--person-key-fd=4",
        "--take-over",
        "--handoff-unix-fd",
        "8",
        "--handoff-count=2",
        "--dev",
    ]
    .map(String::from)
    .to_vec();
    assert_eq!(handover_args(&args), ["acp", "daemon", "run", "--take-over", "--memory", "--dev"]);
}
