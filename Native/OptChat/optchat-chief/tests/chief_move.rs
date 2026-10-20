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
        "agent-token",
        "state/moved-in.json",
    ] {
        assert!(dst.join(kept).is_file(), "{kept} moved");
    }
    for local in [
        "optchat/traces",
        "optchat/claude",
        "host.log",
        "state/host.lock",
        "acpmux/run",
        "acpmux/login-env.json",
        "tui/terminal-hosts-1234",
        "optchat/memory.sqlite3-wal",
    ] {
        assert!(!dst.join(local).exists(), "{local} is machine-local");
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
