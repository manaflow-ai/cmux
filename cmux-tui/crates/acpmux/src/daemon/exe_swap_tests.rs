use super::*;

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
        "--dev",
    ]
    .map(String::from)
    .to_vec();
    assert_eq!(handover_args(&args), ["acp", "daemon", "run", "--take-over", "--memory", "--dev"]);
}
