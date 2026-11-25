use super::*;

fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
    move |name| pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| (*value).into())
}

const IN_A_PANE: &[(&str, &str)] =
    &[("CMUX_TUI_SOCKET", "/tmp/pane.sock"), ("CMUX_TUI_SESSION_ID", "pane-session")];

#[test]
fn live_session_derives_its_socket_like_the_cli_and_ignores_the_panes() {
    let route = live_route(None, Some("w4i-e1"), env(IN_A_PANE)).unwrap();
    assert_eq!(route.socket, cmux::raw::default_socket_path("w4i-e1"));
    assert_ne!(route.socket, PathBuf::from("/tmp/pane.sock"));
    assert_eq!(route.session.as_deref(), Some("w4i-e1"));
}

#[test]
fn live_socket_is_exact_and_reads_its_own_session() {
    let route = live_route(Some("/tmp/exact.sock"), None, env(IN_A_PANE)).unwrap();
    assert_eq!(route, LiveRoute { socket: "/tmp/exact.sock".into(), session: None });
    let both = live_route(Some("/tmp/exact.sock"), Some("w4i"), env(&[])).unwrap();
    assert_eq!(both.session.as_deref(), Some("w4i"));
}

#[test]
fn live_route_without_flags_keeps_the_panes_socket_else_main() {
    let route = live_route(None, None, env(IN_A_PANE)).unwrap();
    assert_eq!(route.socket, PathBuf::from("/tmp/pane.sock"));
    assert_eq!(route.session.as_deref(), Some("pane-session"));
    let mux = live_route(None, None, env(&[("CMUX_MUX_SOCKET", "/tmp/mux.sock")])).unwrap();
    assert_eq!(mux, LiveRoute { socket: "/tmp/mux.sock".into(), session: None });
    let bare = live_route(None, None, env(&[])).unwrap();
    assert_eq!(bare.socket, cmux::raw::default_socket_path("main"));
}

#[test]
fn live_session_names_a_path_component() {
    for name in ["", "..", "a/b", "a\nb"] {
        assert!(live_route(None, Some(name), env(&[])).is_err(), "{name:?}");
    }
}
