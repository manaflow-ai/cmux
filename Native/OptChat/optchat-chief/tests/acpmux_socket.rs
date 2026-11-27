//! The acpmux socket the Chief reaches, against the shared cases
//! (cmux-tui/crates/cmux-agent-pane-policy/tests/cases/environment.json) the
//! Rust policy, the Swift host, cmux-tui and the brain host run too: a
//! configured `ACPMUX_SOCKET` past the Unix socket limit and a long home reach
//! the short alias the daemon binds.

use optchat_chief::acpmux_daemon::{daemon_home_for, socket_path_for};
use serde_json::Value;
use std::path::Path;

fn cases() -> Value {
    let file = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../cmux-tui/crates/cmux-agent-pane-policy/tests/cases/environment.json");
    serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap()
}

#[test]
fn a_homes_default_socket_matches_the_shared_cases() {
    let cases = cases();
    let rows = cases["sockets"].as_array().unwrap();
    assert!(!rows.is_empty());
    for row in rows {
        let home = row[0].as_str().unwrap();
        let got = socket_path_for(
            None,
            Some(home),
            Path::new("/Users/unused"),
            row[1].as_u64().unwrap() as u32,
        );
        assert_eq!(
            got.to_str().unwrap(),
            row[2].as_str().unwrap(),
            "home {home}"
        );
    }
}

#[test]
fn a_configured_socket_matches_the_shared_cases() {
    let cases = cases();
    let rows = cases["configured_sockets"].as_array().unwrap();
    assert!(!rows.is_empty());
    for row in rows {
        let configured = row[0].as_str().unwrap();
        let got = socket_path_for(
            Some(configured).filter(|c| !c.is_empty()),
            Some(row[1].as_str().unwrap()),
            Path::new("/Users/unused"),
            row[2].as_u64().unwrap() as u32,
        );
        assert_eq!(
            got.to_str().unwrap(),
            row[3].as_str().unwrap(),
            "configured {configured}"
        );
    }
}

#[test]
fn a_started_daemons_home_is_never_the_short_alias_folder() {
    let user = Path::new(
        "/Users/a-user-whose-home-folder-name-is-long-enough-to-push-the-default-socket-path",
    );
    let socket = socket_path_for(None, None, user, 501);
    assert!(
        socket.starts_with("/tmp/acpmux-501"),
        "{}",
        socket.display()
    );
    assert_eq!(
        daemon_home_for(None, None, &socket, user, 501),
        user.join(".acpmux")
    );
    let configured = format!("/{}/s.sock", "e".repeat(98));
    let socket = socket_path_for(Some(&configured), None, user, 501);
    assert!(
        socket.starts_with("/tmp/acpmux-501"),
        "{}",
        socket.display()
    );
    assert_eq!(
        daemon_home_for(None, Some(&configured), &socket, user, 501),
        Path::new(&configured).parent().unwrap()
    );
    let socket = Path::new("/tmp/run/acpmux.sock");
    assert_eq!(
        daemon_home_for(None, None, socket, user, 501),
        Path::new("/tmp/run")
    );
}
