use super::*;
use std::process::{Command, Stdio};
use std::time::Duration;

fn spawn(script: &str) -> Child {
    let mut command = Command::new("/bin/sh");
    command.args(["-c", script]).stdin(Stdio::piped()).stdout(Stdio::piped());
    std::os::unix::process::CommandExt::process_group(&mut command, 0);
    command.spawn().unwrap()
}

#[test]
fn a_child_that_finishes_gives_its_output_and_status() {
    let child = spawn("cat; exit 3");
    let done = wait(child, Some(b"hello".to_vec()), None, "cat").unwrap();
    assert_eq!(done.status.code(), Some(3));
    assert_eq!(done.stdout, b"hello");
    assert!(done.written.unwrap().is_ok());
}

#[test]
fn a_stalled_child_and_its_group_end_at_the_deadline() {
    let child = spawn("sleep 30");
    let started = std::time::Instant::now();
    let deadline = Some(Instant::now() + Duration::from_millis(300));
    let error = wait(child, None, deadline, "the stall").unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
    assert!(error.to_string().contains("timed out"), "{error}");
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
}

/// A child someone else already reaped is not proven to hold its group id, so a timeout
/// later signals only the child, never `-pid`.
#[test]
fn a_child_already_reaped_does_not_prove_its_group() {
    let mut child = spawn("exit 0");
    child.wait().unwrap();
    assert!(matches!(exit_within(&mut child, None), Ok(false)));
    let mut running = spawn("exit 0");
    assert!(matches!(exit_within(&mut running, None), Ok(true)));
    running.wait().unwrap();
}

/// The child exits at once, but a descendant keeps its stdout open: the read is bounded
/// too. (tests/send_relay_cli.rs checks that such a descendant is killed with the group.)
#[test]
fn a_descendant_holding_the_output_open_ends_at_the_deadline() {
    let child = spawn("sleep 30 & exit 0");
    let started = std::time::Instant::now();
    let deadline = Some(Instant::now() + Duration::from_millis(300));
    let error = wait(child, None, deadline, "the open").unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
}
