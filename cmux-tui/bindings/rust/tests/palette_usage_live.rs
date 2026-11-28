//! The typed palette usage calls (`palette_usage.get`, `.record`, `.hide`,
//! `.forget`, `.import`; capability `palette-usage-v1`) against a real
//! cmux-tui daemon, over its socket.
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary (the
//! `cmux-tui-sdks.yml` live conformance job sets it). Without the variable the
//! test reports the skip and passes.
// Unix sockets and a live Unix daemon; the Windows suite is separate.
#![cfg(unix)]

use cmux::{Config, MutationOptions, PaletteUsageImportRow};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct Daemon {
    child: Child,
    dir: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A headless daemon in its own state directory.
fn live() -> Option<(Daemon, PathBuf)> {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return None;
    };
    let dir =
        std::env::temp_dir().join(format!("cmux-sdk-palette-usage-live-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    let child = Command::new(binary)
        .args(["--headless", "--session", "sdk-palette-usage", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(dir.join("state"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("start cmux-tui");
    let daemon = Daemon { child, dir };
    let deadline = Instant::now() + Duration::from_secs(30);
    while UnixStream::connect(&socket).is_err() {
        assert!(Instant::now() < deadline, "cmux-tui did not listen on {socket:?}");
        thread::sleep(Duration::from_millis(50));
    }
    Some((daemon, socket))
}

fn connect(socket: &Path) -> cmux::Client {
    cmux::Client::connect(Config::from_socket_path(socket).with_timeout(Duration::from_secs(10)))
        .unwrap()
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

#[test]
fn palette_usage_history_live_daemon() {
    let Some((_daemon, socket)) = live() else { return };
    let client = connect(&socket);
    let session = client.current_session();

    let empty = session.palette_usage().unwrap();
    assert_eq!(empty.revision, 0, "{empty:?}");
    assert!(
        empty.entries.is_empty() && empty.picks.is_empty() && empty.hidden.is_empty(),
        "{empty:?}"
    );
    assert!(empty.half_life_ms > 0 && empty.pick_half_life_ms > 0, "{empty:?}");

    // A use for a query: the row and a learned pick for the query's start.
    let before = now_ms();
    let first = session.record_palette_use("action:splitRight", "Split  R").unwrap();
    assert_eq!(first.value.revision, 1);
    let used = session.palette_usage().unwrap();
    let row = used.entries.iter().find(|r| r.key == "action:splitRight").expect("the used row");
    assert!((row.score - 1.0).abs() < 1e-6 && row.last_used_ms >= before, "{row:?}");
    let picks: Vec<_> = used.picks.iter().filter(|p| p.key == "action:splitRight").collect();
    assert!(
        picks.iter().any(|p| p.prefix == "split r" && p.last),
        "picks keyed by the normalized query: {picks:?}"
    );

    // The same idempotency key replays; a use without a query adds no pick.
    let key = MutationOptions::new("palette-usage-live-1").unwrap();
    let recorded = session.record_palette_use_with("action:newTab", "", key.clone()).unwrap();
    let replayed = session.record_palette_use_with("action:newTab", "", key).unwrap();
    assert!(
        replayed.replayed && replayed.value.revision == recorded.value.revision,
        "{replayed:?}"
    );
    let usage = session.palette_usage().unwrap();
    assert!(
        usage.entries.iter().any(|r| r.key == "action:newTab" && (r.score - 1.0).abs() < 1e-6),
        "{usage:?}"
    );
    assert!(usage.picks.iter().all(|p| p.key != "action:newTab"), "{usage:?}");

    // Hide, then show again.
    session.hide_palette_row("action:newTab", true).unwrap();
    assert_eq!(session.palette_usage().unwrap().hidden, vec!["action:newTab".to_string()]);
    session.hide_palette_row("action:newTab", false).unwrap();
    assert!(session.palette_usage().unwrap().hidden.is_empty());

    // Reset Ranking forgets the row and its picks.
    session.forget_palette_row("action:splitRight").unwrap();
    let forgot = session.palette_usage().unwrap();
    assert!(forgot.entries.iter().all(|r| r.key != "action:splitRight"), "{forgot:?}");
    assert!(forgot.picks.iter().all(|p| p.key != "action:splitRight"), "{forgot:?}");

    // A former history imports once per source.
    let rows = [PaletteUsageImportRow {
        key: "action:openSettings".into(),
        score: 3.0,
        last_used_ms: now_ms(),
    }];
    let imported = session.import_palette_usage("com.example.former", &rows).unwrap();
    assert!(imported.value.imported, "{imported:?}");
    let again = session.import_palette_usage("com.example.former", &rows).unwrap();
    assert!(!again.value.imported, "{again:?}");
    let usage = session.palette_usage().unwrap();
    assert_eq!(usage.imported, vec!["com.example.former".to_string()]);
    assert!(
        usage.entries.iter().any(|r| r.key == "action:openSettings" && r.score > 2.5),
        "{usage:?}"
    );

    // An over-long key is refused before it reaches the daemon, and the
    // history is unchanged.
    let revision = usage.revision;
    assert!(session.record_palette_use(&"k".repeat(513), "").is_err());
    assert_eq!(session.palette_usage().unwrap().revision, revision);
}
