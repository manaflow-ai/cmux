//! Moving a Chief back out of the cloud (plans/cmux-next/chief-migration-DESIGN.md 4b):
//! a home whose `state/moved.json` points at a hosted Cloud Chief moves to a Mac (another
//! home or the same one) or over SSH. The cloud copy is frozen first (its brain off, no
//! turn running), its memory and the messages it got after the move are merged into this
//! home's frozen copy, the result is restored and checked on the target, and only then
//! does the target become the one that answers. The session token comes from the app
//! (`cmux auth token --json`) when no file or variable names one.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

const BIN: &str = env!("CARGO_BIN_EXE_optchat-chief");
const CHIEF: &str = "agent_01TEST";
const USER: &str = "user_T";

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// The daemon session directory of a Chief root (as in chief_move.rs).
fn session_dir(root: &Path) -> String {
    let mut h32: u32 = 0x811c_9dc5;
    for b in root.to_string_lossy().as_bytes() {
        h32 ^= u32::from(*b);
        h32 = h32.wrapping_mul(0x0100_0193);
    }
    let name = format!("cmux-chief-{h32:08x}");
    let mut h64 = 0xcbf2_9ce4_8422_2325_u64;
    for b in name.bytes() {
        h64 ^= u64::from(b);
        h64 = h64.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{name}-{h64:016x}")
}

/// A home that moved to the cloud: a real memory with two messages, the local Chief
/// conversation with two messages, the host's cursor at seq 2, and the move markers.
fn moved_home(dir: &Path, base: &str) -> PathBuf {
    let src = dir.join("src");
    std::fs::create_dir_all(src.join("optchat")).unwrap();
    let src = std::fs::canonicalize(src).unwrap();
    let seed = dir.join("seed.jsonl");
    write(
        &seed,
        "{\"text\":\"the code word is PERIWINKLE-42\",\"kind\":\"user\"}\n{\"text\":\"noted\",\"kind\":\"talk\"}\n",
    );
    let imported = Command::new(BIN)
        .args([
            "import",
            "--mux-home",
            src.to_str().unwrap(),
            seed.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        imported.status.success(),
        "{}",
        String::from_utf8_lossy(&imported.stderr)
    );
    let mem = rusqlite::Connection::open(src.join("optchat/memory.sqlite3")).unwrap();
    mem.execute_batch(
        "INSERT OR REPLACE INTO state VALUES ('host/conversation', '\"conv_L\"');
         INSERT OR REPLACE INTO state VALUES ('host/logged_seq', '2');",
    )
    .unwrap();
    drop(mem);
    let session = src.join("tui").join(session_dir(&src));
    std::fs::create_dir_all(&session).unwrap();
    let conv = rusqlite::Connection::open(session.join("conversations.sqlite3")).unwrap();
    conv.execute_batch(
        r#"CREATE TABLE conversation (id TEXT PRIMARY KEY, title TEXT, participants_json TEXT, last_seq INTEGER, rev INTEGER, created_at TEXT, updated_at TEXT);
           CREATE TABLE message (conversation TEXT, seq INTEGER, id TEXT, message_json TEXT, PRIMARY KEY(conversation, seq)) WITHOUT ROWID;
           CREATE UNIQUE INDEX message_by_id ON message(id);
           CREATE TABLE read_cursor (conversation TEXT, participant TEXT, seq INTEGER, PRIMARY KEY(conversation, participant)) WITHOUT ROWID;
           INSERT INTO conversation VALUES ('conv_L','Chief','[{"id":"user_local"},{"id":"agent_mux"}]',2,2,'','');
           INSERT INTO message VALUES ('conv_L',1,'msg_A','{"id":"msg_A","seq":1,"client_msg_id":"c1","author":"user_local","parts":[{"type":"text","text":"hi"}],"created_at":"2026-10-20T09:00:00.000Z"}');
           INSERT INTO message VALUES ('conv_L',2,'msg_B','{"id":"msg_B","seq":2,"client_msg_id":"t1","author":"agent_mux","parts":[{"type":"text","text":"hello"}],"created_at":"2026-10-20T09:00:01.000Z"}');
           INSERT INTO read_cursor VALUES ('conv_L','agent_mux',2);"#,
    )
    .unwrap();
    drop(conv);
    write(&src.join("optchat/person.md"), "- the person\n");
    write(
        &src.join("state/moved.json"),
        &json!({"to": format!("cloud:{base}/{CHIEF}"), "at": "2026-11-03T00:00:00Z", "checkpoint_sha256": "x"}).to_string(),
    );
    write(&src.join("state/shutdown"), "chief move\n");
    src
}

/// What the fake cloud saw: method, path, body.
type Calls = Arc<Mutex<Vec<(String, String, Value)>>>;

/// A stand-in for the cloud API holding the hosted Chief after the move: the two copied
/// messages plus two it got in the cloud, and a memory that grew by two messages.
fn fake_cloud(local_memory: Vec<(String, String)>) -> (String, Calls) {
    fake_cloud_with(local_memory, None, 0)
}

/// The fake cloud, its Chief having asked to teleport to `teleport`.
fn fake_cloud_asking(
    local_memory: Vec<(String, String)>,
    teleport: Option<&str>,
) -> (String, Calls) {
    fake_cloud_with(local_memory, teleport, 0)
}

/// The fake cloud; its first memory export page is padded by `pad` bytes (a Chief with months of
/// memory sends a first page of more than 10 MB).
fn fake_cloud_with(
    local_memory: Vec<(String, String)>,
    teleport: Option<&str>,
    pad: usize,
) -> (String, Calls) {
    let mut teleport: Value = teleport.map_or(
        Value::Null,
        |to| json!({"to": to, "id": "tp-1", "at": "2026-11-03T00:00:00Z"}),
    );
    use std::io::{BufRead, BufReader, Read, Write as _};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let seen: Calls = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    std::thread::spawn(move || {
        let mut memory: Vec<Value> = local_memory
            .iter()
            .enumerate()
            .map(|(i, (kind, text))| json!({"i": i, "kind": kind, "text": text, "size": text.len(), "date": "2026-11-01T10:00:00.000Z"}))
            .collect();
        for text in [
            "in the cloud: the new code word is TANGERINE-9",
            "noted in the cloud",
        ] {
            let i = memory.len();
            memory.push(json!({"i": i, "kind": if i.is_multiple_of(2) { "user" } else { "talk" }, "text": text, "size": text.len(), "date": "2026-11-02T10:00:00.000Z"}));
        }
        let history = [
            json!({"id": "msg_A", "seq": 1, "client_msg_id": "c1", "author": USER, "parts": [{"type": "text", "text": "hi"}], "created_at": "2026-10-20T09:00:00.000Z"}),
            json!({"id": "msg_B", "seq": 2, "client_msg_id": "t1", "author": CHIEF, "parts": [{"type": "text", "text": "hello"}], "created_at": "2026-10-20T09:00:01.000Z"}),
            json!({"id": "msg_C", "seq": 3, "client_msg_id": "c3", "author": USER, "parts": [{"type": "text", "text": "new in the cloud"}], "created_at": "2026-11-02T10:00:00.000Z"}),
            json!({"id": "msg_D", "seq": 4, "client_msg_id": "t4", "author": CHIEF, "parts": [{"type": "text", "text": "answered from the cloud"}], "created_at": "2026-11-02T10:00:01.000Z"}),
        ];
        let mut brain = true;
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut first = String::new();
            reader.read_line(&mut first).unwrap();
            let mut parts = first.split_whitespace();
            let method = parts.next().unwrap_or("").to_owned();
            let path = parts.next().unwrap_or("").to_owned();
            let (mut length, mut auth) = (0usize, String::new());
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line.trim().is_empty() {
                    break;
                }
                let lower = line.to_ascii_lowercase();
                if let Some(v) = lower.strip_prefix("content-length:") {
                    length = v.trim().parse().unwrap();
                }
                if lower.starts_with("authorization:") {
                    auth = line.trim().to_owned();
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
            log.lock()
                .unwrap()
                .push((method.clone(), path.clone(), body.clone()));
            let query = |key: &str| -> Option<String> {
                path.split_once('?')?.1.split('&').find_map(|kv| {
                    let (k, v) = kv.split_once('=')?;
                    (k == key).then(|| v.to_owned())
                })
            };
            let (status, reply) = if auth != "authorization: Bearer app-token" {
                (401, json!({"ok": false}))
            } else if path.contains("/brain") && method == "PUT" {
                if body.get("teleport").is_some() {
                    teleport = body["teleport"].clone();
                } else {
                    brain = body["enabled"] == true;
                }
                (200, json!({"ok": true, "value": {}}))
            } else if path.contains("/brain") {
                (
                    200,
                    json!({"ok": true, "value": {"config": {"enabled": brain, "teleport": teleport}}}),
                )
            } else if path.contains("/runs") {
                // A turn would still be running while the brain is on.
                let status = if brain { "running" } else { "done" };
                (
                    200,
                    json!({"ok": true, "value": {"runs": [{"id": "run_1", "status": status}], "has_more": false}}),
                )
            } else if path.contains("/memory") && query("export").as_deref() == Some("1") {
                let after: i64 = query("after").unwrap().parse().unwrap();
                let limit: usize = query("limit").unwrap().parse().unwrap();
                let page: Vec<Value> = memory
                    .iter()
                    .filter(|m| m["i"].as_i64().unwrap() > after)
                    .take(limit)
                    .cloned()
                    .collect();
                let nodes = if after < 0 {
                    json!([{"l": 1, "i": 0, "text": "cloud summary of 0 and 1", "size": 24}])
                } else {
                    json!([])
                };
                let pad = if after < 0 {
                    " ".repeat(pad)
                } else {
                    String::new()
                };
                (
                    200,
                    json!({"ok": true, "value": {"count": memory.len(), "messages": page, "nodes": nodes, "logged": [], "checkpoint": null, "cursor": null, "pad": pad}}),
                )
            } else if path == "/v1/read" && body["op"] == "conversation.history" {
                let before = body["params"]["before_seq"].as_u64().unwrap_or(u64::MAX);
                let limit = body["params"]["limit"].as_u64().unwrap_or(50) as usize;
                let older: Vec<Value> = history
                    .iter()
                    .filter(|m| m["seq"].as_u64().unwrap() < before)
                    .cloned()
                    .collect();
                let page: Vec<Value> = older[older.len().saturating_sub(limit)..].to_vec();
                (
                    200,
                    json!({"value": {"messages": page, "has_more": older.len() > limit}}),
                )
            } else {
                (404, json!({"ok": false}))
            };
            let text = reply.to_string();
            let _ = write!(
                stream,
                "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{text}",
                text.len()
            );
        }
    });
    (base, seen)
}

/// A stand-in for the app's `cmux auth token --json`.
fn fake_app_cli(dir: &Path, origin: &str) -> PathBuf {
    let bin = dir.join("bin/cmux");
    write(
        &bin,
        &format!(
            "#!/bin/sh\n[ \"$1 $2 $3\" = \"auth token --json\" ] || exit 9\necho '{}'\n",
            json!({"access_token": "app-token", "token_type": "Bearer", "api_origin": origin, "expires_in": 600})
        ),
    );
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    bin
}

fn local_memory(home: &Path) -> Vec<(String, String)> {
    let conn = rusqlite::Connection::open(home.join("optchat/memory.sqlite3")).unwrap();
    let mut stmt = conn
        .prepare("SELECT kind, text FROM messages ORDER BY id")
        .unwrap();
    stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

fn move_cmd(home: &Path, to: &str, cli: &Path) -> Output {
    Command::new(BIN)
        .args(["move", "--to", to, "--home", home.to_str().unwrap()])
        .env("OPTCHAT_MOVE_CMUX", cli)
        .env_remove("CMUX_CLOUD_SESSION_TOKEN")
        .output()
        .unwrap()
}

fn report(out: &Output) -> Value {
    let stdout = String::from_utf8_lossy(&out.stdout);
    let text = format!("{stdout}{}", String::from_utf8_lossy(&out.stderr));
    assert!(
        !text.contains("app-token"),
        "the token is never printed: {text}"
    );
    serde_json::from_str(stdout.lines().last().unwrap_or(""))
        .unwrap_or_else(|e| panic!("{e}: {text}"))
}

fn conversation(home: &Path) -> Vec<Value> {
    let db = home
        .join("tui")
        .join(session_dir(home))
        .join("conversations.sqlite3");
    let conn = rusqlite::Connection::open(db).unwrap();
    let mut stmt = conn
        .prepare("SELECT message_json FROM message WHERE conversation = 'conv_L' ORDER BY seq")
        .unwrap();
    stmt.query_map([], |r| r.get::<_, String>(0))
        .unwrap()
        .map(|t| serde_json::from_str(&t.unwrap()).unwrap())
        .collect()
}

fn state(home: &Path, key: &str) -> Option<String> {
    let conn = rusqlite::Connection::open(home.join("optchat/memory.sqlite3")).unwrap();
    conn.query_row("SELECT value FROM state WHERE key = ?1", [key], |r| {
        r.get(0)
    })
    .ok()
}

/// Brain PUTs in order; the cloud copy must go off and never come back on.
fn brain_puts(seen: &Calls) -> Vec<bool> {
    seen.lock()
        .unwrap()
        .iter()
        .filter(|c| c.0 == "PUT" && c.1.contains("/brain") && c.2.get("enabled").is_some())
        .map(|c| c.2["enabled"] == true)
        .collect()
}

#[test]
fn a_cloud_chief_moves_to_another_home_with_what_it_learned_in_the_cloud() {
    let dir = tempfile::tempdir().unwrap();
    let probe = tempfile::tempdir().unwrap();
    // The fake cloud repeats the home's own two memory messages first.
    let seed_home = moved_home(probe.path(), "http://127.0.0.1:1");
    let (base, seen) = fake_cloud(local_memory(&seed_home));
    let src = moved_home(dir.path(), &base);
    let cli = fake_app_cli(dir.path(), &base);
    let dst = dir.path().join("dst");
    let out = move_cmd(&src, &format!("local:{}", dst.display()), &cli);
    let r = report(&out);
    assert_eq!(r["moved"], true, "{r}");
    assert_eq!(r["memory"]["messages"], 4, "{r}");
    assert_eq!(r["conversations"]["messages"], 4, "{r}");
    let dst = std::fs::canonicalize(&dst).unwrap();
    let mem = local_memory(&dst);
    assert_eq!(mem.len(), 4);
    assert!(mem[2].1.contains("TANGERINE-9"), "{mem:?}");
    let conv = conversation(&dst);
    assert_eq!(conv.len(), 4);
    assert_eq!(conv[2]["author"], "user_local");
    assert_eq!(conv[3]["author"], "agent_mux");
    assert_eq!(conv[3]["parts"][0]["text"], "answered from the cloud");
    // The host does not log the cloud's messages a second time.
    assert_eq!(state(&dst, "host/logged_seq").as_deref(), Some("4"));
    assert_eq!(brain_puts(&seen), vec![false], "frozen once, never back on");
    let moved: Value =
        serde_json::from_str(&std::fs::read_to_string(src.join("state/moved.json")).unwrap())
            .unwrap();
    let to = moved["to"]
        .as_str()
        .unwrap()
        .strip_prefix("local:")
        .unwrap();
    assert_eq!(std::fs::canonicalize(to).unwrap(), dst);
    assert!(!dst.join("state/moved.json").exists());
}

#[test]
fn a_cloud_chief_whose_memory_export_is_larger_than_10_mb_comes_back() {
    let dir = tempfile::tempdir().unwrap();
    let probe = tempfile::tempdir().unwrap();
    let seed_home = moved_home(probe.path(), "http://127.0.0.1:1");
    // The real Chief's first page was 16 MB (20391 messages, 2026-11-03).
    let (base, _seen) = fake_cloud_with(local_memory(&seed_home), None, 16 << 20);
    let src = moved_home(dir.path(), &base);
    let cli = fake_app_cli(dir.path(), &base);
    let dst = dir.path().join("dst");
    let out = move_cmd(&src, &format!("local:{}", dst.display()), &cli);
    let r = report(&out);
    assert_eq!(r["moved"], true, "{r}");
    assert_eq!(r["memory"]["messages"], 4, "{r}");
}

#[test]
fn a_cloud_chief_comes_back_into_the_home_it_left() {
    let dir = tempfile::tempdir().unwrap();
    let probe = tempfile::tempdir().unwrap();
    let seed_home = moved_home(probe.path(), "http://127.0.0.1:1");
    let (base, seen) = fake_cloud(local_memory(&seed_home));
    let src = moved_home(dir.path(), &base);
    let cli = fake_app_cli(dir.path(), &base);
    let out = move_cmd(&src, &format!("local:{}", src.display()), &cli);
    let r = report(&out);
    assert_eq!(r["moved"], true, "{r}");
    assert_eq!(local_memory(&src).len(), 4);
    assert_eq!(conversation(&src).len(), 4);
    assert!(
        !src.join("state/moved.json").exists(),
        "this home answers again"
    );
    assert!(!src.join("state/shutdown").exists());
    assert_eq!(brain_puts(&seen), vec![false]);
}

#[test]
fn a_dry_run_out_of_the_cloud_changes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let probe = tempfile::tempdir().unwrap();
    let seed_home = moved_home(probe.path(), "http://127.0.0.1:1");
    let (base, seen) = fake_cloud(local_memory(&seed_home));
    let src = moved_home(dir.path(), &base);
    let cli = fake_app_cli(dir.path(), &base);
    let out = Command::new(BIN)
        .args([
            "move",
            "--dry-run",
            "--to",
            &format!("local:{}", dir.path().join("dst").display()),
            "--home",
            src.to_str().unwrap(),
        ])
        .env("OPTCHAT_MOVE_CMUX", &cli)
        .env_remove("CMUX_CLOUD_SESSION_TOKEN")
        .output()
        .unwrap();
    let r = report(&out);
    assert!(r["error"].is_null(), "{r}");
    assert!(
        brain_puts(&seen).is_empty(),
        "a dry run never freezes the cloud copy"
    );
    assert!(src.join("state/moved.json").exists());
    assert!(!dir.path().join("dst").exists());
}

#[test]
fn the_app_token_for_another_cloud_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let probe = tempfile::tempdir().unwrap();
    let seed_home = moved_home(probe.path(), "http://127.0.0.1:1");
    let (base, seen) = fake_cloud(local_memory(&seed_home));
    let src = moved_home(dir.path(), &base);
    // The app is signed in to production; the Chief is on the fake cloud.
    let cli = fake_app_cli(dir.path(), "https://cloud-api.cmux.dev");
    let out = move_cmd(
        &src,
        &format!("local:{}", dir.path().join("dst").display()),
        &cli,
    );
    assert!(!out.status.success());
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("signed in to https://cloud-api.cmux.dev"),
        "{err}"
    );
    assert!(
        seen.lock().unwrap().is_empty(),
        "no call with a token for another cloud"
    );
    assert!(src.join("state/moved.json").exists());
}

/// A stand-in `ssh` that runs the remote command in `remote_home` (as chief_move.rs).
fn fake_ssh(dir: &Path, remote_home: &Path) -> PathBuf {
    let path = dir.join("fake-ssh");
    write(
        &path,
        &format!(
            "#!/bin/sh\nwhile [ \"$1\" = -o ]; do shift 2; done\nshift\ncd '{h}' && HOME='{h}' exec sh -c \"$1\"\n",
            h = remote_home.display()
        ),
    );
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// The round trip the person asks for in chat: this Mac -> cloud -> Mac mini -> this
/// Mac. The Cloud Chief asks to go to the mini (its teleport tool), the Chief on the
/// mini asks to come home (its move tool's request file); this Mac's watcher carries
/// out both, and the home ends with every message from every stop.
#[test]
fn a_round_trip_from_the_cloud_to_a_mini_and_home_loses_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let probe = tempfile::tempdir().unwrap();
    let seed_home = moved_home(probe.path(), "http://127.0.0.1:1");
    let (base, seen) = fake_cloud_asking(local_memory(&seed_home), Some("ssh:mini"));
    let src = moved_home(dir.path(), &base);
    let cli = fake_app_cli(dir.path(), &base);
    let remote = dir.path().join("mini-user");
    std::fs::create_dir_all(&remote).unwrap();
    let remote = std::fs::canonicalize(remote).unwrap();
    let ssh = fake_ssh(dir.path(), &remote);
    // The watcher's first look: the Cloud Chief asked for the mini.
    let first = Command::new(BIN)
        .args([
            "move",
            "watch",
            "--every",
            "1",
            "--remote-bin",
            BIN,
            "--home",
            src.to_str().unwrap(),
        ])
        .env("OPTCHAT_MOVE_CMUX", &cli)
        .env("OPTCHAT_MOVE_SSH", &ssh)
        .env_remove("CMUX_CLOUD_SESSION_TOKEN")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let on_mini = remote.join(".cmux/chief/src");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(120);
    // Bounded wait for the watcher's first move: its flip (moved.json naming the mini) comes
    // after the mini's moved-in.json, so wait for the flip itself.
    let flipped = || {
        std::fs::read_to_string(src.join("state/moved.json"))
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            .is_some_and(|m| m["to"].as_str().is_some_and(|t| t.starts_with("ssh:mini:")))
    };
    while !flipped() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    assert!(on_mini.join("state/moved-in.json").exists());
    let moved: Value =
        serde_json::from_str(&std::fs::read_to_string(src.join("state/moved.json")).unwrap())
            .unwrap();
    assert!(
        moved["to"].as_str().unwrap().starts_with("ssh:mini:"),
        "{moved}"
    );
    assert_eq!(
        local_memory(&on_mini).len(),
        4,
        "the cloud's memory reached the mini"
    );
    assert_eq!(brain_puts(&seen), vec![false]);
    assert!(
        seen.lock()
            .unwrap()
            .iter()
            .any(|c| c.2.get("teleport").is_some_and(Value::is_null)),
        "the cloud request is cleared"
    );
    // A conversation message on the mini, then its Chief asks to come home.
    let mini_conv = on_mini
        .join("tui")
        .join(session_dir(&on_mini))
        .join("conversations.sqlite3");
    let conn = rusqlite::Connection::open(&mini_conv).unwrap();
    conn.execute_batch(
        r#"INSERT INTO message VALUES ('conv_L',5,'msg_E','{"id":"msg_E","seq":5,"author":"user_local","parts":[{"type":"text","text":"said on the mini"}]}');
           UPDATE conversation SET last_seq = 5;"#,
    )
    .unwrap();
    drop(conn);
    write(
        &on_mini.join("state/teleport-request.json"),
        &json!({"to": "home", "id": "tp-2"}).to_string(),
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(120);
    let mut first = first;
    while first.try_wait().unwrap().is_none() && std::time::Instant::now() < deadline {
        // Bounded wait for the watcher to bring the Chief home and exit.
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    let _ = first.kill();
    assert!(
        !src.join("state/moved.json").exists(),
        "the home answers again"
    );
    assert_eq!(local_memory(&src).len(), 4);
    let conv = conversation(&src);
    assert_eq!(conv.len(), 5, "{conv:?}");
    assert_eq!(conv[4]["parts"][0]["text"], "said on the mini");
    assert!(
        on_mini.join("state/moved.json").exists(),
        "the mini's copy is retired"
    );
    assert!(!on_mini.join("state/teleport-request.json").exists());
}

/// `move --to local:<the home>` on a home that moved over SSH brings it back.
#[test]
fn a_chief_on_a_mini_comes_back_into_the_home_it_left() {
    let dir = tempfile::tempdir().unwrap();
    let probe = tempfile::tempdir().unwrap();
    let seed_home = moved_home(probe.path(), "http://127.0.0.1:1");
    let (base, _seen) = fake_cloud(local_memory(&seed_home));
    let src = moved_home(dir.path(), &base);
    let cli = fake_app_cli(dir.path(), &base);
    let remote = dir.path().join("mini-user");
    std::fs::create_dir_all(&remote).unwrap();
    let remote = std::fs::canonicalize(remote).unwrap();
    let ssh = fake_ssh(dir.path(), &remote);
    let run = |to: String| {
        Command::new(BIN)
            .args([
                "move",
                "--to",
                &to,
                "--remote-bin",
                BIN,
                "--home",
                src.to_str().unwrap(),
            ])
            .env("OPTCHAT_MOVE_CMUX", &cli)
            .env("OPTCHAT_MOVE_SSH", &ssh)
            .env_remove("CMUX_CLOUD_SESSION_TOKEN")
            .output()
            .unwrap()
    };
    let r = report(&run("ssh:mini".into()));
    assert_eq!(r["moved"], true, "{r}");
    let r = report(&run(format!("local:{}", src.display())));
    assert_eq!(r["moved"], true, "{r}");
    assert!(!src.join("state/moved.json").exists());
    assert_eq!(local_memory(&src).len(), 4);
    assert_eq!(conversation(&src).len(), 4);
}
