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
        "messagingSocketPath": socket, "status": "idle", "startedAt": now_ms(),
    })
}

fn now_ms() -> u64 {
    let since = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap();
    u64::try_from(since.as_millis()).unwrap()
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn an_entry_names_a_sender_only_while_its_process_is_the_one_that_wrote_it() {
    let dir = scratch("reused");
    let me = std::process::id();
    let write = |record: Value| {
        std::fs::write(dir.join(format!("sessions/{me}.json")), record.to_string()).unwrap();
        live(&dir).into_iter().map(|p| p.session_id).collect::<Vec<_>>()
    };
    let sock = dir.join("me.sock");
    assert_eq!(write(entry(me, "mine", "claude-desktop", &sock)), ["mine"]);
    // Written by an app that started (and ended) long before this process took its pid.
    let mut stale = entry(me, "stale", "claude-desktop", &sock);
    stale["startedAt"] = json!(1_000);
    assert!(write(stale).is_empty(), "a reused pid never stands in for a stale entry");
    // No start time recorded: the entry cannot be tied to this process, so it is refused.
    let mut unknown = entry(me, "unknown", "claude-desktop", &sock);
    unknown.as_object_mut().unwrap().remove("startedAt");
    assert!(write(unknown).is_empty(), "an entry with no start time names no sender");
    let _ = std::fs::remove_dir_all(&dir);
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
    deliver(&dir, &peer, "hello desk", "u-9", "acpmux:test", None).await.unwrap();
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
    let err = deliver(&dir, &peer, "x", "u", "f", None).await.unwrap_err();
    assert!(err.contains("missing or unreadable"), "no key, nothing sent: {err}");
    let key = key_file(&dir, 1, &dir.join("gone.sock"));
    std::fs::write(key, json!({"peerToken": "0123456789abcdef0123456789abcdef"}).to_string())
        .unwrap();
    let err = deliver(&dir, &peer, "x", "u", "f", None).await.unwrap_err();
    assert!(err.contains("could not reach"), "{err}");
}

#[cfg(unix)]
#[tokio::test]
async fn a_registered_child_token_opens_the_delivery_instead_of_the_peer_key() {
    let dir = scratch("child-token");
    let sock = dir.join("in.sock");
    let listener = std::os::unix::net::UnixListener::bind(&sock).unwrap();
    let reader = std::thread::spawn(move || {
        use std::io::Read;
        let (mut conn, _) = listener.accept().unwrap();
        let mut got = String::new();
        conn.read_to_string(&mut got).unwrap();
        got
    });
    let peer = Peer {
        pid: 1,
        session_id: "s".into(),
        cwd: None,
        entrypoint: Some("claude-desktop".into()),
        kind: None,
        name: None,
        version: None,
        socket: Some(sock.clone()),
    };
    // No key file: the child token alone opens it.
    deliver(&dir, &peer, "hi", "u-c", "acpmux:test", Some("child-tok")).await.unwrap();
    let got = reader.join().unwrap();
    let lines: Vec<Value> = got.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines[0], json!({"type": "auth", "token": "child-tok"}));
    assert_eq!(lines[1]["type"], "user");
    assert_eq!(lines[1]["from"], "acpmux:test");
}

#[test]
fn a_kept_token_is_the_live_sessions_only_while_its_process_and_inbox_are_the_same() {
    let home = scratch("token-store");
    let sock = PathBuf::from("/tmp/cc-socks/42.sock");
    let kept = ChildToken { pid: 42, socket: sock.clone(), token: "tok".into(), started: Some(7) };
    save_token(&home, "chat-1", &kept).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(token_file(&home, "chat-1")).unwrap().permissions().mode();
        assert_eq!(mode & 0o077, 0, "owner-only");
    }
    let mut peer = Peer {
        pid: 42,
        session_id: "s".into(),
        cwd: None,
        entrypoint: None,
        kind: None,
        name: None,
        version: None,
        socket: Some(sock),
    };
    assert_eq!(token_for(&home, "chat-1", &peer, Some(7)).as_deref(), Some("tok"));
    assert_eq!(
        token_for(&home, "chat-2", &peer, Some(7)),
        None,
        "another chat's is not this one's"
    );
    assert_eq!(token_for(&home, "chat-1", &peer, Some(8)), None, "a later process under the pid");
    assert_eq!(token_for(&home, "chat-1", &peer, None), None, "no proven start, no token");
    peer.pid = 43;
    assert_eq!(
        token_for(&home, "chat-1", &peer, Some(7)),
        None,
        "a restarted session has a new token"
    );
    peer.pid = 42;
    peer.socket = Some(PathBuf::from("/tmp/cc-socks/other.sock"));
    assert_eq!(token_for(&home, "chat-1", &peer, Some(7)), None);
    forget_token(&home, "chat-1");
    peer.socket = Some(PathBuf::from("/tmp/cc-socks/42.sock"));
    assert_eq!(token_for(&home, "chat-1", &peer, Some(7)), None);
    // A chat id never leaves the folder.
    assert_eq!(token_file(&home, "../x").parent(), Some(home.join("bridge-tokens").as_path()));
}

/// A second live entry claiming the same conversation (anyone may write one) proves neither.
#[test]
fn a_conversation_two_live_entries_claim_is_neither_ones() {
    let peer = |pid: u32, id: &str| Peer {
        pid,
        session_id: id.into(),
        cwd: None,
        entrypoint: None,
        kind: None,
        name: None,
        version: None,
        socket: None,
    };
    let (mine, forged, other) = (peer(42, "sid"), peer(43, "sid"), peer(44, "other"));
    assert!(sole_claimant(&mine, &[mine.clone(), other.clone()]));
    assert!(!sole_claimant(&mine, &[mine.clone(), forged.clone(), other]));
    assert!(!sole_claimant(&forged, &[mine, forged.clone()]));
}

/// A process is Claude Code only by its signature: this test binary, whatever its name, is not.
#[test]
fn a_process_that_is_not_signed_as_claude_code_is_not_claude_code() {
    assert!(!is_claude_code(std::process::id()));
}

/// The conversation a launch names is read from the kernel's record of its arguments, in every
/// spelling Claude Code takes.
#[test]
fn a_launch_names_its_conversation_in_any_spelling() {
    let args = |a: &[&str]| a.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    assert_eq!(resumed_session(&args(&["claude", "--resume=abc-1"])).as_deref(), Some("abc-1"));
    assert_eq!(
        resumed_session(&args(&["claude", "--resume", "abc-2", "-p"])).as_deref(),
        Some("abc-2")
    );
    assert_eq!(resumed_session(&args(&["claude", "-r", "abc-3"])).as_deref(), Some("abc-3"));
    assert_eq!(resumed_session(&args(&["claude", "--session-id=abc-4"])).as_deref(), Some("abc-4"));
    assert_eq!(resumed_session(&args(&["claude", "--resume", "--print"])), None);
    assert_eq!(resumed_session(&args(&["claude", "-c"])), None);
    // Repro (99c410fe): after `--` it is a prompt, not a flag.
    assert_eq!(resumed_session(&args(&["claude", "--", "--resume=victim"])), None);
    assert_eq!(resumed_session(&args(&["claude", "--", "--resume", "victim"])), None);
    // The operand of the option before it.
    assert_eq!(
        resumed_session(&args(&["claude", "--append-system-prompt", "--resume=victim"])),
        None
    );
    assert_eq!(resumed_session(&args(&["claude", "--model", "-r", "victim"])), None);
    // Repro (b101a26b F2): a boolean flag takes no value, so a restart after one still names it.
    assert_eq!(
        resumed_session(&args(&["claude", "--verbose", "--resume", "sid"])).as_deref(),
        Some("sid")
    );
    assert_eq!(resumed_session(&args(&["claude", "-p", "--resume=sid"])).as_deref(), Some("sid"));
    assert_eq!(resumed_session(&args(&["claude", "--debug", "-r", "sid"])).as_deref(), Some("sid"));
    // An option Claude does not list as boolean may take it as its value.
    assert_eq!(resumed_session(&args(&["claude", "--await-initialize", "--resume=sid"])), None);
    // Two sessions named: neither.
    assert_eq!(resumed_session(&args(&["claude", "--resume=a", "--session-id=b"])), None);
    // A desktop launch: inline values throughout.
    let desktop = ["claude", "--output-format=stream-json", "--resume=s-1", "--allowedTools=x,y"];
    assert_eq!(resumed_session(&args(&desktop)).as_deref(), Some("s-1"));
    // KERN_PROCARGS2: argc, the executable path, padding to 8 bytes, the arguments, the env.
    let raw = |argc: i32, path: &str, rest: &[&str]| {
        let mut buf = argc.to_ne_bytes().to_vec();
        buf.extend_from_slice(path.as_bytes());
        buf.resize(buf.len() + 8 - path.len() % 8, 0);
        for part in rest {
            buf.extend_from_slice(part.as_bytes());
            buf.push(0);
        }
        buf
    };
    let got = procargs(&raw(3, "/bin/claude", &["claude", "--resume=s-9", "-p", "HOME=/x"]));
    assert_eq!(
        got,
        Some(args(&["claude", "--resume=s-9", "-p"])),
        "the environment is not an argument"
    );
    // A path that fills its 8 bytes still gets a full 8 of padding.
    let got = procargs(&raw(1, "/a/claude/claude", &["claude", "HOME=/x"]));
    assert_eq!(got, Some(args(&["claude"])));
    // Repro (a418d95a F2): an empty argument stays one, so argc never reaches the environment.
    let buf = raw(
        4,
        "/bin/claude",
        &["claude", "--append-system-prompt", "", "hello", "--resume=victim"],
    );
    let got = procargs(&buf).unwrap();
    assert_eq!(got, args(&["claude", "--append-system-prompt", "", "hello"]));
    assert_eq!(resumed_session(&got), None);
    // Repro (b101a26b F1): an empty argv[0] is not padding; it fails closed.
    assert_eq!(procargs(&raw(2, "/bin/claude", &["", "--verbose", "--resume=victim"])), None);
    assert_eq!(procargs(&raw(2, "/bin/claude", &["", "claude", "--resume=victim"])), None);
    // Padding of the wrong length, or argv[0] naming another program: nothing.
    let mut short = 2i32.to_ne_bytes().to_vec();
    short.extend_from_slice(b"/bin/claude\0\0claude\0-p\0");
    assert_eq!(procargs(&short), None);
    assert_eq!(procargs(&raw(2, "/bin/claude", &["sh", "-p", "X=1"])), None);
    // Fewer arguments than argc: nothing.
    assert_eq!(procargs(&raw(3, "/bin/claude", &["claude"])), None);
    // The desktop launches by full path; the CLI by its link.
    let app = "/Apps/claude.app/Contents/MacOS/claude";
    assert!(procargs(&raw(2, app, &[app, "--resume=s-1", "HOME=/x"])).is_some());
    // Repro (a418d95a F1): a forked launch starts a new conversation, in any position.
    for fork in [
        &["claude", "--resume=victim", "--fork-session"][..],
        &["claude", "--fork-session", "--resume", "victim"],
        &["claude", "-r", "victim", "--fork-session=true"],
        &["claude", "--session-id=victim", "--fork-session"],
    ] {
        assert_eq!(resumed_session(&args(fork)), None, "{fork:?}");
    }
}
