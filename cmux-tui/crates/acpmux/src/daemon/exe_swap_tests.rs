use super::*;

/// The status of a real child that ends as `script` makes it.
fn ended(script: &str) -> std::process::ExitStatus {
    cmux_process::Command::new("sh")
        .args(["-c", script])
        .stdin(cmux_process::Stdio::null())
        .status()
        .unwrap()
}

#[test]
fn a_keepalive_launchd_job_exits_after_readiness_without_starting_a_successor() {
    let label = "com.cmux.acpmux.daemon.077f602dcb3c3936";
    for domain in ["system", "gui/501"] {
        let restart = launchd_restart_plan(label, 501, 420, |job| {
            (job == format!("{domain}/{label}"))
                .then(|| "state = running\npid = 420\nproperties = keepalive | runatload\n".into())
        });
        assert_eq!(restart, ServiceRestart::ExitForLaunchd);
        // Only --version succeeds; any attempt to invoke this program as a daemon fails.
        let dir = tempfile::tempdir().unwrap();
        let installed = dir.path().join("acpmux");
        std::fs::write(&installed, "#!/bin/sh\n[ \"$1\" = --version ]\n").unwrap();
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&installed, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut steps = ExeSwap { installed, args: Vec::new(), restart };
        assert!(matches!(
            cmux_supervise_core::make_before_break(&mut steps, READY_WITHIN),
            Swapped::New
        ));
    }
}

#[test]
fn a_one_shot_aqua_job_needs_its_manager_to_restart_it() {
    let label = "com.cmux.acpmux.daemon.077f602dcb3c3936";
    let plan = launchd_restart_plan(label, 501, 420, |job| {
        (job == format!("gui/501/{label}"))
            .then(|| "\tpid = 420\n\t\tproperties = keepalive\n\tproperties = runatload\n".into())
    });
    assert_eq!(
        plan,
        ServiceRestart::Command(vec![
            "launchctl".into(),
            "kickstart".into(),
            "-k".into(),
            format!("gui/501/{label}")
        ])
    );
}

#[test]
fn only_acpmux_launchd_labels_are_supervised() {
    assert!(is_acpmux_launchd_label("com.acpmux.daemon"));
    assert!(is_acpmux_launchd_label("com.cmux.acpmux.daemon.077f602dcb3c3936"));
    assert!(!is_acpmux_launchd_label("0"));
    assert!(!is_acpmux_launchd_label("application.com.cmux.cmux"));
}

#[test]
fn a_launchagent_with_unusable_gui_output_uses_its_stable_label() {
    let label = "com.acpmux.daemon";
    let command = launchd_restart_plan(label, 501, 420, |_| None);
    assert_eq!(
        command,
        ServiceRestart::Command(vec![
            "launchctl".into(),
            "kickstart".into(),
            "-k".into(),
            format!("gui/501/{label}"),
        ])
    );
}

#[test]
fn a_launchd_job_with_no_matching_pid_is_not_restarted_as_a_takeover() {
    let label = "com.cmux.acpmux.daemon.077f602dcb3c3936";
    let plan =
        launchd_restart_plan(label, 501, 420, |_| Some("state = running\npid = 419\n".into()));
    assert_eq!(plan, ServiceRestart::SupervisedButUnresolved { label: label.into(), pid: 420 });
    assert!(!matches!(plan, ServiceRestart::Unmanaged | ServiceRestart::Command(_)));
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
