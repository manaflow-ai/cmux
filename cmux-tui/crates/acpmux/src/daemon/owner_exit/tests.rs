use super::*;

#[test]
fn quit_helpers_only_another_real_pid_names_an_owner() {
    assert_eq!(owner_pid(Some("4242")), Some(4242));
    assert_eq!(owner_pid(Some(" 4242\n")), Some(4242));
    assert_eq!(owner_pid(None), None);
    assert_eq!(owner_pid(Some("")), None);
    assert_eq!(owner_pid(Some("app")), None);
    assert_eq!(owner_pid(Some("0")), None);
    assert_eq!(owner_pid(Some("1")), None);
    assert_eq!(owner_pid(Some(&std::process::id().to_string())), None);
    assert_eq!(owner_pid(Some("4294967295")), None);
}

#[cfg(debug_assertions)]
#[test]
fn a_test_owner_names_its_pid_and_start_time() {
    assert_eq!(test_owner(Some("4242:917")), Some((4242, Some(917))));
    assert_eq!(test_owner(Some(" 4242\n")), Some((4242, None)));
    assert_eq!(test_owner(Some("4242:x")), None);
    assert_eq!(test_owner(Some("1:917")), None);
    assert_eq!(test_owner(None), None);
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn a_process_keeps_its_start_time_and_a_gone_one_has_none() {
    let mut child = std::process::Command::new("sleep").arg("30").spawn().unwrap();
    let start = process_start(child.id());
    assert!(start.is_some());
    assert_eq!(process_start(child.id()), start);
    assert!(process_start(std::process::id()).is_some_and(|own| Some(own) <= start));
    child.kill().unwrap();
    child.wait().unwrap();
    assert_eq!(process_start(child.id()), None);
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn quit_helpers_the_watch_returns_when_the_process_exits() {
    let mut child = std::process::Command::new("sleep").arg("600").spawn().expect("sleep");
    let pid = child.id();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(imp::wait_exit(pid, || true).is_ok());
    });
    assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "returned while it runs");
    let _ = child.kill();
    let _ = child.wait();
    assert_eq!(rx.recv_timeout(Duration::from_secs(5)), Ok(true));
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn quit_helpers_the_watch_returns_at_once_for_a_process_already_gone() {
    let mut child = std::process::Command::new("true").spawn().expect("true");
    let pid = child.id();
    let _ = child.wait();
    assert!(imp::wait_exit(pid, || true).is_ok());
}

/// A pid that names another process once the watch holds it counts as an exit at once.
#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn a_watch_whose_process_is_not_ours_returns_at_once() {
    let mut child = std::process::Command::new("sleep").arg("600").spawn().expect("sleep");
    let returned = imp::wait_exit(child.id(), || false).is_ok();
    let _ = child.kill();
    let _ = child.wait();
    assert!(returned);
}
