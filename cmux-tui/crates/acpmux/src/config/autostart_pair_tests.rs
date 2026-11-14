use super::*;

/// A removed test home is never made again for a daemon; the default home still is.
#[test]
fn only_the_default_home_is_created_for_a_start() {
    let dir = tempfile::tempdir().unwrap();
    let gone = dir.path().join("removed-test-home");
    let own = gone.join("acpmux.sock");
    let why = autostart_refusal(&gone, true, None, &own).expect("a missing home is refused");
    assert!(why.contains("does not exist"), "{why}");
    assert!(!gone.exists());
    let default = default_home();
    let own = default.join("acpmux.sock");
    assert_eq!(autostart_refusal(&default, false, None, &own), None);
    assert_eq!(autostart_refusal(dir.path(), true, None, &dir.path().join("s.sock")), None);
}

/// `ACPMUX_SOCKET` pairs only with an explicit `ACPMUX_HOME` (or is the home's own): the
/// Chief's socket with no home must not start a daemon under `~/.acpmux`'s lock.
#[test]
fn a_socket_pairs_only_with_an_explicit_home_or_its_own() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let own = home.join("acpmux.sock");
    // Another home's socket, as the Chief's would be.
    let elsewhere = tempfile::tempdir().unwrap();
    let chief_socket = elsewhere.path().join("acpmux.sock");
    let chief = chief_socket.as_path();
    let why = autostart_refusal(home, false, Some(chief), &own).expect("unpaired");
    assert!(why.contains(&chief.display().to_string()), "{why}");
    assert!(why.contains(&own.display().to_string()), "{why}");
    assert_eq!(autostart_refusal(home, true, Some(chief), &own), None);
    assert_eq!(autostart_refusal(home, false, Some(&own), &own), None);
    assert_eq!(autostart_refusal(home, false, None, &own), None);
}
