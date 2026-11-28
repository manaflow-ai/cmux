use cmux_agent_pane_policy::build_identity::BuildIdentity;

use super::app_daemon_socket_for;

/// An agent chat's Computer Use bridge reaches its own app's daemon, never `main`.
#[test]
fn a_chat_bridge_names_its_apps_daemon() {
    let tagged =
        BuildIdentity::new(Some("com.cmuxterm.app.debug.cu.preview2"), Some("cu-preview2"));
    let path = app_daemon_socket_for(&tagged, None).expect("a tagged build has a daemon");
    assert!(path.ends_with("cmux-app-cu-preview2.sock"), "{}", path.display());
    let release = BuildIdentity::new(Some("com.cmuxterm.app"), None);
    let path = app_daemon_socket_for(&release, None).expect("release has a daemon");
    assert!(path.ends_with("cmux-app.sock"), "{}", path.display());
    assert!(app_daemon_socket_for(&BuildIdentity::new(None, None), None).is_none());
}
