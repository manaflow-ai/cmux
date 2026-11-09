use super::*;
use serde_json::json;

fn scratch(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("acpmux-claude-peers-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("sessions")).unwrap();
    dir
}

fn entry(pid: u32, id: &str, entrypoint: &str, socket: &Path) -> Value {
    json!({
        "pid": pid, "sessionId": id, "cwd": "/work", "entrypoint": entrypoint,
        "kind": "interactive", "version": "2.1.310", "name": "desk chat",
        "messagingSocketPath": socket, "status": "idle",
    })
}

#[test]
fn an_entry_reads_its_fields() {
    let peer = parse_entry(&entry(7, "abc", "claude-desktop", Path::new("/s/7.sock"))).unwrap();
    assert_eq!(peer.pid, 7);
    assert_eq!(peer.session_id, "abc");
    assert_eq!(peer.entrypoint.as_deref(), Some("claude-desktop"));
    assert_eq!(peer.name.as_deref(), Some("desk chat"));
    assert_eq!(peer.socket.as_deref(), Some(Path::new("/s/7.sock")));
    assert!(parse_entry(&json!({"pid": 7})).is_none(), "no session id: not an entry");
}

#[test]
fn only_live_pid_entries_are_listed() {
    let dir = scratch("live");
    let me = std::process::id();
    let sock = dir.join("me.sock");
    std::fs::write(
        dir.join(format!("sessions/{me}.json")),
        entry(me, "live-id", "claude-desktop", &sock).to_string(),
    )
    .unwrap();
    // A pid that cannot run (above pid_max), and an entry whose name and pid disagree.
    std::fs::write(
        dir.join("sessions/99999999.json"),
        entry(99_999_999, "dead", "cli", &sock).to_string(),
    )
    .unwrap();
    std::fs::write(dir.join("sessions/1.json"), entry(me, "renamed", "cli", &sock).to_string())
        .unwrap();
    std::fs::write(dir.join("sessions/notes.txt"), "x").unwrap();
    let ids: Vec<String> = live(&dir).into_iter().map(|p| p.session_id).collect();
    assert_eq!(ids, vec!["live-id".to_owned()]);
    assert!(find(&dir, "live-id").is_some());
    assert!(find(&dir, "dead").is_none());
}

#[test]
fn the_key_file_is_named_by_the_socket_paths_sha256() {
    let key = key_file(Path::new("/c"), 42, Path::new("/run/user/1/cc-socks/42.sock"));
    // sha256("/run/user/1/cc-socks/42.sock")
    let want = Sha256::digest(b"/run/user/1/cc-socks/42.sock");
    let hex: String = want.iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(key, PathBuf::from(format!("/c/sessions/42.{hex}.key")));
}

#[test]
fn frames_are_an_auth_line_then_a_user_line() {
    let out = frames(Some("t0k"), "hi\nthere", "u-1", "acpmux:me");
    let lines: Vec<Value> = out.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines[0], json!({"type": "auth", "token": "t0k"}));
    assert_eq!(lines[1]["type"], "user");
    assert_eq!(lines[1]["uuid"], "u-1");
    assert_eq!(lines[1]["from"], "acpmux:me");
    assert_eq!(lines[1]["message"], json!({"role": "user", "content": "hi\nthere"}));
    assert_eq!(frames(None, "x", "u", "f").lines().count(), 1, "no token: no auth line");
}

#[test]
fn a_from_address_keeps_only_address_characters() {
    assert_eq!(from_address("some host/review 42"), "acpmux:some-host/review-42");
    assert!(from_address(&"x".repeat(1000)).len() <= 300);
}

#[test]
fn entrypoints_default_to_the_desktop_app() {
    assert_eq!(entrypoints_of(&Value::Null), vec!["claude-desktop".to_owned()]);
    let doc = json!({"agents": {"desktopBridge": {"entrypoints": ["claude-desktop", "cli"]}}});
    assert_eq!(entrypoints_of(&doc), vec!["claude-desktop".to_owned(), "cli".to_owned()]);
}

#[cfg(unix)]
#[tokio::test]
async fn deliver_authenticates_and_writes_the_message_to_the_inbox() {
    use std::io::Read;
    let dir = scratch("deliver");
    let sock = dir.join("inbox.sock");
    let listener = std::os::unix::net::UnixListener::bind(&sock).unwrap();
    let pid = std::process::id();
    let key = key_file(&dir, pid, &sock);
    std::fs::write(&key, json!({"peerToken": "0123456789abcdef0123456789abcdef"}).to_string())
        .unwrap();
    let peer = Peer {
        pid,
        session_id: "s".into(),
        cwd: None,
        entrypoint: None,
        kind: None,
        name: None,
        version: None,
        socket: Some(sock.clone()),
    };
    let reader = std::thread::spawn(move || {
        let (mut conn, _) = listener.accept().unwrap();
        let mut got = String::new();
        conn.read_to_string(&mut got).unwrap();
        got
    });
    deliver(&dir, &peer, "hello desk", "u-9", "acpmux:test").await.unwrap();
    let got = reader.join().unwrap();
    let lines: Vec<Value> = got.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines[0]["token"], "0123456789abcdef0123456789abcdef");
    assert_eq!(lines[1]["message"]["content"], "hello desk");
    assert_eq!(lines[1]["uuid"], "u-9");
}

#[cfg(unix)]
#[tokio::test]
async fn deliver_sends_nothing_without_a_key_and_names_an_inbox_it_cannot_reach() {
    let dir = scratch("unreachable");
    let peer = Peer {
        pid: 1,
        session_id: "s".into(),
        cwd: None,
        entrypoint: None,
        kind: None,
        name: None,
        version: None,
        socket: Some(dir.join("gone.sock")),
    };
    let err = deliver(&dir, &peer, "x", "u", "f").await.unwrap_err();
    assert!(err.contains("missing or unreadable"), "no key, nothing sent: {err}");
    let key = key_file(&dir, 1, &dir.join("gone.sock"));
    std::fs::write(key, json!({"peerToken": "0123456789abcdef0123456789abcdef"}).to_string())
        .unwrap();
    let err = deliver(&dir, &peer, "x", "u", "f").await.unwrap_err();
    assert!(err.contains("could not reach"), "{err}");
}
