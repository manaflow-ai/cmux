//! Moving a Chief between hosts (plans/cmux-next/chief-migration-DESIGN.md):
//! checkpoint, restore into an empty home with another root, verify, the
//! source's moved marker that the host refuses, rollback, and the SSH path
//! (through a stand-in `ssh` that runs the remote command locally).

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, Instant};

use serde_json::Value;

const BIN: &str = env!("CARGO_BIN_EXE_optchat-chief");

/// The daemon session directory of a Chief root (cmux-tui `ChiefHome::session`
/// then `session_storage_component`), written out here on purpose: the lib's
/// own copy is pinned to a real home by its unit test.
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

fn run(args: &[&str]) -> Output {
    Command::new(BIN).args(args).output().unwrap()
}

fn ok_json(out: &Output) -> Value {
    assert!(
        out.status.success(),
        "exit {:?}\nstdout {}\nstderr {}",
        out.status,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    serde_json::from_str(text.lines().last().unwrap_or(""))
        .unwrap_or_else(|e| panic!("{e}: {text}"))
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// A Chief home with memory (WAL rows not yet checkpointed: the returned
/// connection holds them), a conversation, a subagent transcript, another
/// Chief under `c/`, and machine-local files a move must leave behind.
fn chief_home(root: &Path) -> rusqlite::Connection {
    let root = std::fs::canonicalize(root).unwrap();
    let mem = rusqlite::Connection::open(root.join("optchat/memory.sqlite3")).unwrap();
    mem.query_row("PRAGMA journal_mode = WAL", [], |r| r.get::<_, String>(0))
        .unwrap();
    mem.execute_batch(
        "PRAGMA wal_autocheckpoint = 0;
         CREATE TABLE messages (id INTEGER PRIMARY KEY, kind TEXT, text TEXT);
         CREATE TABLE nodes (level INTEGER, idx INTEGER, text TEXT);
         CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;",
    )
    .unwrap();
    // The host state rows (state.rs HOST_PREFIX): `control cloud PEER` (a306)
    // and `control cap N` are saved here and must move with the Chief.
    mem.execute_batch(
        "INSERT INTO state VALUES ('host/cloud_peer', '\"chief-subagents-1\"');
         INSERT INTO state VALUES ('host/live_cap', '12');",
    )
    .unwrap();
    for i in 0..40 {
        mem.execute(
            "INSERT INTO messages (kind, text) VALUES ('user', ?1)",
            [format!("message {i}")],
        )
        .unwrap();
    }
    for i in 0..7 {
        mem.execute("INSERT INTO nodes VALUES (1, ?1, 'summary')", [i])
            .unwrap();
    }
    let session = root.join("tui").join(session_dir(&root));
    std::fs::create_dir_all(&session).unwrap();
    let conv = rusqlite::Connection::open(session.join("conversations.sqlite3")).unwrap();
    conv.execute_batch(
        "CREATE TABLE message (seq INTEGER PRIMARY KEY, text TEXT);
         INSERT INTO message (text) VALUES ('hi'), ('hello'), ('move to the mini');",
    )
    .unwrap();
    drop(conv);
    write(&session.join("attachments/a.png"), "png");
    write(&root.join("optchat/person.md"), "- the person\n");
    write(&root.join("optchat/chat/main/2026-10-20.jsonl"), "{}\n");
    write(&root.join("acpmux/sessions/s1/events"), "transcript\n");
    write(&root.join("acpmux/config.json"), "{}");
    write(&root.join("c/abc123/optchat/person.md"), "- other chief\n");
    write(&root.join("agent-token"), "tok\n");
    // A preset that names the home: the target's copy names the new home.
    write(
        &root.join("acpmux/presets/p/config.json"),
        &format!("{{\"cwd\":\"{}/optchat/session\"}}", root.display()),
    );
    // Bound to the session name and machine: the target's daemon makes its own.
    write(&session.join("workspace-registry.sqlite3"), "registry");
    write(&session.join("launch-snapshot.json"), "{}");
    write(&root.join("tui/machine-id"), "m");
    write(&root.join("tui/resource-effect-pepper"), "p");
    // Machine-local.
    write(&root.join("optchat/traces/t.jsonl"), "x");
    write(&root.join("optchat/claude/settings.json"), "{}");
    write(&root.join("host.log"), "log");
    write(&root.join("state/host.lock"), "");
    write(&root.join("acpmux/run/x"), "");
    write(&root.join("acpmux/login-env.json"), "{\"secret\":1}");
    write(&root.join("tui/terminal-hosts-1234/a.live"), "");
    mem
}

fn new_home(dir: &Path, name: &str) -> PathBuf {
    let home = dir.join(name);
    std::fs::create_dir_all(home.join("optchat")).unwrap();
    std::fs::canonicalize(home).unwrap()
}

fn state_value(db: &Path, key: &str) -> Option<String> {
    let conn = rusqlite::Connection::open(db).unwrap();
    conn.query_row("SELECT value FROM state WHERE key = ?1", [key], |r| {
        r.get(0)
    })
    .ok()
}

/// The run-time Chief settings saved in the host state carry over.
fn assert_settings_moved(target: &Path) {
    let db = target.join("optchat/memory.sqlite3");
    assert_eq!(
        state_value(&db, "host/cloud_peer").as_deref(),
        Some("\"chief-subagents-1\""),
        "control cloud PEER moves with the Chief"
    );
    assert_eq!(
        state_value(&db, "host/live_cap").as_deref(),
        Some("12"),
        "control cap moves"
    );
}

fn count(db: &Path, table: &str) -> i64 {
    let conn = rusqlite::Connection::open(db).unwrap();
    conn.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}

#[test]
fn checkpoint_then_restore_under_another_root_keeps_every_message() {
    let dir = tempfile::tempdir().unwrap();
    let src = new_home(dir.path(), "src");
    let _mem = chief_home(&src);
    let ckpt = dir.path().join("ckpt");
    let made = ok_json(&run(&[
        "move",
        "checkpoint",
        "--home",
        src.to_str().unwrap(),
        "--out",
        ckpt.to_str().unwrap(),
    ]));
    assert_eq!(
        made["memory"]["messages"], 40,
        "WAL rows are in the copy: {made}"
    );
    assert_eq!(made["memory"]["nodes"], 7);
    assert_eq!(made["conversations"]["messages"], 3);

    let dst = dir.path().join("elsewhere").join("chief");
    let restored = ok_json(&run(&[
        "move",
        "restore",
        "--from",
        ckpt.to_str().unwrap(),
        "--home",
        dst.to_str().unwrap(),
    ]));
    let dst = std::fs::canonicalize(&dst).unwrap();
    assert_eq!(restored["memory"]["messages"], 40);
    assert_eq!(restored["conversations"]["messages"], 3);
    assert_eq!(count(&dst.join("optchat/memory.sqlite3"), "messages"), 40);
    let session = dst.join("tui").join(session_dir(&dst));
    assert_eq!(
        count(&session.join("conversations.sqlite3"), "message"),
        3,
        "session dir renamed for the new root"
    );
    assert!(session.join("attachments/a.png").is_file());
    for kept in [
        "optchat/person.md",
        "optchat/chat/main/2026-10-20.jsonl",
        "acpmux/sessions/s1/events",
        "c/abc123/optchat/person.md",
        "state/moved-in.json",
    ] {
        assert!(dst.join(kept).is_file(), "{kept} moved");
    }
    let preset = std::fs::read_to_string(dst.join("acpmux/presets/p/config.json")).unwrap();
    assert!(
        preset.contains(&format!("{}/optchat/session", dst.display()))
            && !preset.contains(&src.display().to_string()),
        "the old home path is rewritten: {preset}"
    );
    for local in [
        "optchat/traces",
        "optchat/claude",
        "host.log",
        "state/host.lock",
        "acpmux/run",
        "acpmux/login-env.json",
        "tui/terminal-hosts-1234",
        "optchat/memory.sqlite3-wal",
        "agent-token",
        "tui/machine-id",
        "tui/resource-effect-pepper",
    ] {
        assert!(!dst.join(local).exists(), "{local} is machine-local");
    }
    for bound in ["workspace-registry.sqlite3", "launch-snapshot.json"] {
        assert!(
            !session.join(bound).exists(),
            "{bound} is bound to the source session"
        );
    }
    let verified = ok_json(&run(&["move", "verify", "--home", dst.to_str().unwrap()]));
    assert_eq!(verified["memory"]["messages"], 40);
    assert_eq!(verified["conversations"]["messages"], 3);
}

#[test]
fn without_transcripts_leaves_subagent_sessions_behind() {
    let dir = tempfile::tempdir().unwrap();
    let src = new_home(dir.path(), "src");
    let _mem = chief_home(&src);
    let ckpt = dir.path().join("ckpt");
    ok_json(&run(&[
        "move",
        "checkpoint",
        "--without-transcripts",
        "--home",
        src.to_str().unwrap(),
        "--out",
        ckpt.to_str().unwrap(),
    ]));
    assert!(!ckpt.join("files/acpmux/sessions").exists());
    assert!(ckpt.join("files/acpmux/config.json").is_file());
}

#[test]
fn restore_refuses_a_tampered_checkpoint_and_writes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let src = new_home(dir.path(), "src");
    let _mem = chief_home(&src);
    let ckpt = dir.path().join("ckpt");
    ok_json(&run(&[
        "move",
        "checkpoint",
        "--home",
        src.to_str().unwrap(),
        "--out",
        ckpt.to_str().unwrap(),
    ]));
    std::fs::write(ckpt.join("files/optchat/person.md"), "- someone else\n").unwrap();
    let dst = dir.path().join("dst");
    let out = run(&[
        "move",
        "restore",
        "--from",
        ckpt.to_str().unwrap(),
        "--home",
        dst.to_str().unwrap(),
    ]);
    assert!(!out.status.success());
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("person.md"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(!dst.exists());
}

#[test]
fn restore_refuses_a_home_that_is_not_empty() {
    let dir = tempfile::tempdir().unwrap();
    let src = new_home(dir.path(), "src");
    let _mem = chief_home(&src);
    let ckpt = dir.path().join("ckpt");
    ok_json(&run(&[
        "move",
        "checkpoint",
        "--home",
        src.to_str().unwrap(),
        "--out",
        ckpt.to_str().unwrap(),
    ]));
    let dst = dir.path().join("dst");
    write(&dst.join("optchat/person.md"), "- the target's own Chief\n");
    let out = run(&[
        "move",
        "restore",
        "--from",
        ckpt.to_str().unwrap(),
        "--home",
        dst.to_str().unwrap(),
    ]);
    assert!(!out.status.success());
    assert_eq!(
        std::fs::read_to_string(dst.join("optchat/person.md")).unwrap(),
        "- the target's own Chief\n"
    );
}

#[test]
fn checkpoint_refuses_while_the_host_runs() {
    let dir = tempfile::tempdir().unwrap();
    let src = new_home(dir.path(), "src");
    let _mem = chief_home(&src);
    let _held = optchat_chief::lock::HostLock::take(&src.join("state/host.lock"), 1).unwrap();
    let ckpt = dir.path().join("ckpt");
    let out = run(&[
        "move",
        "checkpoint",
        "--home",
        src.to_str().unwrap(),
        "--out",
        ckpt.to_str().unwrap(),
    ]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("running"));
    let moved = run(&[
        "move",
        "--to",
        &format!("local:{}", dir.path().join("dst").display()),
        "--home",
        src.to_str().unwrap(),
    ]);
    assert!(
        !moved.status.success(),
        "a move does not stop a host without --stop-host"
    );
    assert!(!src.join("state/moved.json").exists());
    assert!(
        !src.join("state/shutdown").exists(),
        "a refused move holds nothing"
    );
}

/// Runs the host on `home` with no daemon; returns its exit code (None: still running after 10 s).
fn host_exit(home: &Path) -> (Option<i32>, String) {
    let token = home.join("test-token");
    std::fs::write(&token, "secret\n").unwrap();
    let mut child = Command::new(BIN)
        .args(["host", "--daemon-socket"])
        .arg(home.join("missing.sock"))
        .arg("--mux-home")
        .arg(home)
        .env("MUX_AGENT_TOKEN_FILE", &token)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            let out = child.wait_with_output().unwrap();
            return (
                status.code(),
                String::from_utf8_lossy(&out.stderr).into_owned(),
            );
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            return (None, String::new());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn a_move_marks_the_source_the_host_refuses_it_and_rollback_brings_it_back() {
    let dir = tempfile::tempdir().unwrap();
    let src = new_home(dir.path(), "src");
    let mem = chief_home(&src);
    drop(mem);
    let dst = dir.path().join("mini").join("chief");
    let report = ok_json(&run(&[
        "move",
        "--to",
        &format!("local:{}", dst.display()),
        "--home",
        src.to_str().unwrap(),
    ]));
    assert_eq!(report["moved"], true, "{report}");
    assert_eq!(report["memory"]["messages"], 40);
    assert_settings_moved(&std::fs::canonicalize(&dst).unwrap());
    let steps: Vec<&str> = report["steps"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["step"].as_str().unwrap())
        .collect();
    assert_eq!(
        steps,
        [
            "preflight",
            "drain",
            "checkpoint",
            "transfer+restore",
            "verify",
            "commit"
        ]
    );
    assert!(src.join("state/moved.json").is_file());
    assert!(
        src.join("state/shutdown").is_file(),
        "the app starts no brain on the source"
    );
    let leftovers: Vec<_> = std::fs::read_dir(dir.path())
        .unwrap()
        .filter_map(Result::ok)
        .filter(|e| e.file_name().to_string_lossy().starts_with(".chief-move"))
        .collect();
    assert!(leftovers.is_empty(), "the temp checkpoint is removed");

    let (code, stderr) = host_exit(&src);
    assert_eq!(code, Some(3), "the host refuses a moved home: {stderr}");
    assert!(stderr.contains("moved to"), "{stderr}");

    let again = run(&[
        "move",
        "--to",
        &format!("local:{}", dir.path().join("third").display()),
        "--home",
        src.to_str().unwrap(),
    ]);
    assert!(!again.status.success(), "a moved home does not move twice");

    let back = run(&["move", "rollback", "--home", src.to_str().unwrap()]);
    assert!(
        back.status.success(),
        "{}",
        String::from_utf8_lossy(&back.stderr)
    );
    assert!(!src.join("state/moved.json").exists());
    assert!(!src.join("state/shutdown").exists());
    let dst = std::fs::canonicalize(&dst).unwrap();
    assert!(
        dst.join("state/moved.json").is_file(),
        "the target is marked moved back"
    );
}

#[test]
fn dry_run_checks_the_target_and_changes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let src = new_home(dir.path(), "src");
    let _mem = chief_home(&src);
    let dst = dir.path().join("dst");
    let report = ok_json(&run(&[
        "move",
        "--dry-run",
        "--to",
        &format!("local:{}", dst.display()),
        "--home",
        src.to_str().unwrap(),
    ]));
    assert_eq!(report["moved"], false);
    assert!(!dst.exists());
    assert!(!src.join("state/shutdown").exists());
}

/// A stand-in `ssh`: drops the options and the host, runs the command with
/// `sh -c` in a fake remote home.
fn fake_ssh(dir: &Path, remote_home: &Path) -> PathBuf {
    let path = dir.join("fake-ssh");
    std::fs::write(
        &path,
        format!(
            "#!/bin/sh\nwhile [ \"$1\" = -o ]; do shift 2; done\nshift\ncd '{h}' && HOME='{h}' exec sh -c \"$1\"\n",
            h = remote_home.display()
        ),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

#[test]
fn a_move_over_ssh_restores_with_the_remote_optchat_chief() {
    let dir = tempfile::tempdir().unwrap();
    let src = new_home(dir.path(), "default");
    let mem = chief_home(&src);
    drop(mem);
    let remote = dir.path().join("remote-user");
    std::fs::create_dir_all(&remote).unwrap();
    let remote = std::fs::canonicalize(remote).unwrap();
    let ssh = fake_ssh(dir.path(), &remote);
    let out = Command::new(BIN)
        .args([
            "move",
            "--to",
            "ssh:mini",
            "--remote-bin",
            BIN,
            "--home",
            src.to_str().unwrap(),
        ])
        .env("OPTCHAT_MOVE_SSH", &ssh)
        .output()
        .unwrap();
    let report = ok_json(&out);
    assert_eq!(report["moved"], true, "{report}");
    let target = remote.join(".cmux/chief/default");
    assert_eq!(
        count(&target.join("optchat/memory.sqlite3"), "messages"),
        40,
        "same home name under the remote's ~/.cmux/chief"
    );
    assert_eq!(
        count(
            &target
                .join("tui")
                .join(session_dir(&target))
                .join("conversations.sqlite3"),
            "message"
        ),
        3
    );
    assert!(
        !remote.join(".cmux/chief/default.checkpoint").exists(),
        "the staging copy is removed"
    );
    assert_settings_moved(&target);
    let moved: Value =
        serde_json::from_str(&std::fs::read_to_string(src.join("state/moved.json")).unwrap())
            .unwrap();
    assert!(
        moved["to"].as_str().unwrap().starts_with("ssh:mini:"),
        "{moved}"
    );

    let back = Command::new(BIN)
        .args([
            "move",
            "rollback",
            "--remote-bin",
            BIN,
            "--home",
            src.to_str().unwrap(),
        ])
        .env("OPTCHAT_MOVE_SSH", &ssh)
        .output()
        .unwrap();
    assert!(
        back.status.success(),
        "{}",
        String::from_utf8_lossy(&back.stderr)
    );
    assert!(target.join("state/moved.json").is_file());
    assert!(!src.join("state/moved.json").exists());
}

#[test]
fn a_move_carries_reach_by_name_only_and_the_backup_repository() {
    let dir = tempfile::tempdir().unwrap();
    let user_home = dir.path().join("user");
    write(
        &user_home.join(".ssh/config"),
        "Host bogus-reach-host\n  HostName 127.0.0.1\n  Port 1\n  IdentityFile ~/.ssh/id_very_secret\n",
    );
    write(
        &user_home.join(".ssh/id_very_secret"),
        "PRIVATE KEY MATERIAL",
    );
    let src = new_home(dir.path(), "src");
    let _mem = chief_home(&src);
    let dst = dir.path().join("dst");
    let out = Command::new(BIN)
        .args([
            "move",
            "--to",
            &format!("local:{}", dst.display()),
            "--home",
            src.to_str().unwrap(),
        ])
        .env("HOME", &user_home)
        .env("PATH", "/usr/bin:/bin")
        .output()
        .unwrap();
    assert_eq!(ok_json(&out)["moved"], true);
    let dst = std::fs::canonicalize(&dst).unwrap();
    let reach = std::fs::read_to_string(dst.join("optchat/reach-source.json")).unwrap();
    assert!(reach.contains("bogus-reach-host"), "{reach}");
    assert!(
        reach.contains("id_very_secret"),
        "the key is listed by name: {reach}"
    );
    assert!(!reach.contains("PRIVATE KEY MATERIAL") && !reach.contains("IdentityFile"));
    // The backup repository follows the Chief, not the new path.
    let src_id = optchat_chief::paths::home_id(&src);
    assert_eq!(
        std::fs::read_to_string(dst.join("optchat/backup-id"))
            .unwrap()
            .trim(),
        src_id
    );
    assert_eq!(optchat_chief::migrate::backup_id(&dst), src_id);
    let probe = Command::new(BIN)
        .args(["move", "reach", "--home", dst.to_str().unwrap()])
        .env("HOME", &user_home)
        .env("PATH", "/usr/bin:/bin")
        .output()
        .unwrap();
    let probe = ok_json(&probe);
    assert_eq!(
        probe["ssh"]["unreachable"][0], "bogus-reach-host",
        "{probe}"
    );
    assert!(
        probe["blockers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|b| b.as_str().unwrap().contains("SSH"))
    );
}

#[test]
fn a_chief_moving_itself_waits_for_its_turn_to_end() {
    let dir = tempfile::tempdir().unwrap();
    let src = new_home(dir.path(), "src");
    let _mem = chief_home(&src);
    let trace = src.join("optchat/traces/2026-10-20.jsonl");
    write(&trace, "{\"ev\":\"turn.start\",\"ts\":1}\n");
    let dst = dir.path().join("dst");
    let started = run(&[
        "move",
        "--detach",
        "--to",
        &format!("local:{}", dst.display()),
        "--home",
        src.to_str().unwrap(),
    ]);
    let started = ok_json(&started);
    assert_eq!(started["scheduled"], true, "{started}");
    std::thread::sleep(Duration::from_secs(2));
    assert!(!dst.exists(), "nothing moves while the turn runs");
    assert!(!src.join("state/moved.json").exists());
    use std::io::Write as _;
    std::fs::OpenOptions::new()
        .append(true)
        .open(&trace)
        .unwrap()
        .write_all(b"{\"ev\":\"turn.end\",\"ts\":2}\n")
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    while !src.join("state/move.json").exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(200));
    }
    let report: Value =
        serde_json::from_str(&std::fs::read_to_string(src.join("state/move.json")).unwrap())
            .unwrap();
    assert_eq!(report["moved"], true, "{report}");
    assert!(src.join("state/moved.json").is_file());
    assert_eq!(
        count(
            &std::fs::canonicalize(&dst)
                .unwrap()
                .join("optchat/memory.sqlite3"),
            "messages"
        ),
        40
    );
}

#[test]
fn the_chief_has_a_move_tool_and_a_dry_run_changes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let src = new_home(dir.path(), "src");
    let _mem = chief_home(&src);
    let dst = dir.path().join("dst");
    let socket = src.join("optchat/tools.sock");
    let input = format!(
        "{}\n{}\n{}\n",
        serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}),
        serde_json::json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
        serde_json::json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "move", "arguments": {"to": format!("local:{}", dst.display()), "dry_run": true}}}),
    );
    let mut child = Command::new(BIN)
        .args(["mcp", "--socket", socket.to_str().unwrap()])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    use std::io::Write as _;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    let lines: Vec<Value> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    let list = lines.iter().find(|l| l["id"] == 2).unwrap();
    assert!(
        list["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t["name"] == "move"),
        "{list}"
    );
    let call = lines.iter().find(|l| l["id"] == 3).unwrap();
    assert_eq!(call["result"]["isError"], false, "{call}");
    let text = call["result"]["content"][0]["text"].as_str().unwrap();
    assert!(
        text.contains("\"dry_run\":true") && text.contains("preflight"),
        "{text}"
    );
    assert!(!dst.exists());
    assert!(!src.join("state/moved.json").exists());
}

/// A stand-in for the cloud API (the calls the app's Hosted Chief copy makes).
/// The calls the fake cloud received: method, path, body.
type Calls = std::sync::Arc<std::sync::Mutex<Vec<(String, String, Value)>>>;

fn fake_cloud() -> (String, Calls) {
    use std::io::{BufRead, BufReader, Read, Write as _};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let log = seen.clone();
    std::thread::spawn(move || {
        let mut memory = 0u64;
        let mut done = false;
        let mut brain = false;
        let mut history = 0u64;
        let mut sent = 0u64;
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut first = String::new();
            reader.read_line(&mut first).unwrap();
            let mut parts = first.split_whitespace();
            let method = parts.next().unwrap_or("").to_owned();
            let path = parts.next().unwrap_or("").to_owned();
            let mut length = 0usize;
            let mut auth = String::new();
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
            let (status, reply) = if auth != "authorization: Bearer test-session" {
                (401, serde_json::json!({"ok": false}))
            } else if path.ends_with("/agent_00000000000000000000000000/brain") {
                (403, serde_json::json!({"ok": false}))
            } else if path == "/v1/ops" && body["op"] == "chief.create" {
                (
                    200,
                    serde_json::json!({"ok": true, "value": {"id": "agent_01TEST", "owner_user": "user_T", "main_conversation": "conv_MAIN"}}),
                )
            } else if path == "/v1/ops" && body["op"] == "conversation.import" {
                history += body["params"]["messages"].as_array().unwrap().len() as u64;
                (
                    200,
                    serde_json::json!({"ok": true, "value": {"last_seq": history}}),
                )
            } else if path == "/v1/ops" && body["op"] == "message.send" {
                // The hosted Chief answers at once.
                sent += 1;
                (200, serde_json::json!({"ok": true, "value": {}}))
            } else if path == "/v1/ops" {
                (200, serde_json::json!({"ok": true, "value": {}}))
            } else if path == "/v1/read" {
                // A read answers {value} without `ok` (the real API's shape).
                let mut messages =
                    vec![serde_json::json!({"seq": history, "author": "user_T", "parts": []})];
                if sent > 0 {
                    messages.push(serde_json::json!({"seq": history + 1, "author": "user_T", "parts": [{"type": "text", "text": "q"}]}));
                    messages.push(serde_json::json!({"seq": history + 2, "author": "agent_01TEST", "parts": [{"type": "text", "text": "MARIGOLD-77"}]}));
                }
                (200, serde_json::json!({"value": {"messages": messages}}))
            } else if path.contains("/brain") && method == "PUT" {
                brain = body["enabled"] == true;
                (200, serde_json::json!({"ok": true}))
            } else if path.contains("/brain") {
                (
                    200,
                    serde_json::json!({"ok": true, "value": {"config": {"enabled": brain}}}),
                )
            } else if path.contains("/memory") && method == "PUT" {
                assert_eq!(body["after"], memory);
                memory += body["main"].as_array().unwrap().len() as u64;
                done = body["done"] == true;
                (200, serde_json::json!({"ok": true}))
            } else if path.contains("/memory") {
                let state = if done {
                    "done"
                } else if memory == 0 {
                    "empty"
                } else {
                    "importing"
                };
                (
                    200,
                    serde_json::json!({"ok": true, "value": {"count": memory, "state": state}}),
                )
            } else {
                (404, serde_json::json!({"ok": false}))
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

#[test]
fn a_move_to_the_cloud_copies_history_and_memory_and_turns_the_brain_on() {
    let dir = tempfile::tempdir().unwrap();
    let src = new_home(dir.path(), "src");
    let mem = chief_home(&src);
    drop(mem);
    // A real memory store: the cloud copy reads the memory's text export.
    std::fs::remove_file(src.join("optchat/memory.sqlite3")).unwrap();
    let seed = dir.path().join("seed.jsonl");
    write(
        &seed,
        "{\"text\":\"the code word is PERIWINKLE-42\",\"kind\":\"user\"}\n{\"text\":\"noted\",\"kind\":\"talk\"}\n",
    );
    let imported = run(&[
        "import",
        "--mux-home",
        src.to_str().unwrap(),
        seed.to_str().unwrap(),
    ]);
    assert!(
        imported.status.success(),
        "{}",
        String::from_utf8_lossy(&imported.stderr)
    );
    // The local Chief conversation in the owner's shape.
    let session = src.join("tui").join(session_dir(&src));
    std::fs::remove_file(session.join("conversations.sqlite3")).unwrap();
    let conv = rusqlite::Connection::open(session.join("conversations.sqlite3")).unwrap();
    conv.execute_batch(
        r#"CREATE TABLE conversation (id TEXT PRIMARY KEY, title TEXT, participants_json TEXT, last_seq INTEGER, rev INTEGER, created_at TEXT, updated_at TEXT);
           CREATE TABLE message (conversation TEXT, seq INTEGER, id TEXT, message_json TEXT, PRIMARY KEY(conversation, seq)) WITHOUT ROWID;
           INSERT INTO conversation VALUES ('conv_L','Chief','[{"id":"user_local"},{"id":"agent_mux"}]',2,2,'','');
           INSERT INTO message VALUES ('conv_L',1,'msg_A','{"id":"msg_A","seq":1,"client_msg_id":"c1","author":"user_local","parts":[{"type":"text","text":"hi"}],"created_at":"2026-10-20T09:00:00.000Z"}');
           INSERT INTO message VALUES ('conv_L',2,'msg_B','{"id":"msg_B","seq":2,"client_msg_id":"t1","author":"agent_mux","parts":[{"type":"text","text":"hello"}],"created_at":"2026-10-20T09:00:01.000Z"}');"#,
    )
    .unwrap();
    drop(conv);
    let (base, seen) = fake_cloud();
    let token = dir.path().join("session");
    std::fs::write(&token, "test-session\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&token, std::fs::Permissions::from_mode(0o600)).unwrap();
    let out = Command::new(BIN)
        .args([
            "move",
            "--to",
            &format!("cloud:{base}"),
            "--session-token-file",
            token.to_str().unwrap(),
            "--home",
            src.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(
        !text.contains("test-session"),
        "the token is never printed: {text}"
    );
    let report = ok_json(&out);
    assert_eq!(report["moved"], true, "{report}");
    assert_eq!(report["cloud"]["chief"], "agent_01TEST");
    assert_eq!(report["cloud"]["history_imported"], 2);
    assert_eq!(report["cloud"]["memory_messages"], 2);
    let calls = seen.lock().unwrap().clone();
    let import = calls
        .iter()
        .find(|c| c.2["op"] == "conversation.import")
        .unwrap();
    assert_eq!(import.2["params"]["messages"][0]["author"], "user_T");
    assert_eq!(import.2["params"]["messages"][1]["author"], "agent_01TEST");
    assert!(
        calls
            .iter()
            .any(|c| c.2["op"] == "conversation.import.commit")
    );
    let brain_puts: Vec<&Value> = calls
        .iter()
        .filter(|c| c.0 == "PUT" && c.1.contains("/brain"))
        .map(|c| &c.2)
        .collect();
    assert_eq!(
        brain_puts.last().unwrap()["enabled"],
        true,
        "the brain is on at the end"
    );
    let moved: Value =
        serde_json::from_str(&std::fs::read_to_string(src.join("state/moved.json")).unwrap())
            .unwrap();
    assert_eq!(moved["to"], format!("cloud:{base}/agent_01TEST"));
    // One message to the moved Chief, and its reply.
    let asked = Command::new(BIN)
        .args([
            "move",
            "ask",
            "--text",
            "the code word?",
            "--session-token-file",
            token.to_str().unwrap(),
            "--home",
            src.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        asked.status.success(),
        "{}",
        String::from_utf8_lossy(&asked.stderr)
    );
    assert!(String::from_utf8_lossy(&asked.stdout).contains("MARIGOLD-77"));
    // Rollback turns the hosted brain off and lets this copy answer again.
    let back = Command::new(BIN)
        .args([
            "move",
            "rollback",
            "--session-token-file",
            token.to_str().unwrap(),
            "--home",
            src.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        back.status.success(),
        "{}",
        String::from_utf8_lossy(&back.stderr)
    );
    assert!(!src.join("state/moved.json").exists());
    let calls = seen.lock().unwrap().clone();
    let last_brain = calls
        .iter()
        .rev()
        .find(|c| c.0 == "PUT" && c.1.contains("/brain"))
        .unwrap();
    assert_eq!(last_brain.2["enabled"], false);
}
