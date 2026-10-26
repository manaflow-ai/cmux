//! Fresh-Chief eval, placement step (a650+, user 12374): a Chief a new person gets
//! (clean home, default grant, no memory) must make a workspace for every subagent, with
//! or without the cmux app's socket in its environment.

use optchat_chief::workspaces::{Placement, placement};

fn no_env(_: &str) -> Option<String> {
    None
}

#[test]
fn a_host_without_app_or_install_uses_its_own_daemon() {
    assert_eq!(
        placement(false, "/h/owner.sock", &no_env, None),
        Placement::OwnDaemon("/h/owner.sock".into()),
        "a fresh local Chief with no CMUX_SOCKET_PATH must still get workspaces"
    );
}

#[test]
fn the_app_wins_when_its_socket_is_in_the_environment() {
    let env = |k: &str| (k == "CMUX_SOCKET_PATH").then(|| "/app/cmux.sock".to_owned());
    assert!(matches!(
        placement(false, "/h/owner.sock", &env, None),
        Placement::App(_)
    ));
}

#[test]
fn a_cloud_install_without_an_app_uses_the_install() {
    assert_eq!(
        placement(false, "/h/o.sock", &no_env, Some("inst1")),
        Placement::Cloud("/h/o.sock".into(), "inst1".into())
    );
}

#[test]
fn the_off_switch_still_turns_workspaces_off() {
    assert_eq!(placement(true, "/h/o.sock", &no_env, None), Placement::Off);
}
