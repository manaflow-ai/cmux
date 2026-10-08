//! The start reads what the view needs, not the log: a saved checkpoint,
//! the view's parts and the frontier nodes by key (README "State and
//! storage", resource use). The 1M-message check is ignored by default:
//!
//! ```bash
//! cargo test --release --test start -- --ignored --nocapture
//! ```

mod common;

use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

use common::*;
use optchat_host::db::checkpoint::Loaded;
use optchat_host::*;

#[test]
fn a_restart_resumes_from_the_checkpoint_with_the_same_view() {
    let dir = tempfile::tempdir().unwrap();
    let live = {
        let chat = open(dir.path(), 6_000, instant(300));
        // A fresh memory is folded (nothing to resume from) once.
        assert_eq!(chat.loaded(), Loaded::Folded);
        for n in 0..700 {
            let text = if n % 3 == 0 {
                long(n)
            } else {
                format!("short {n}")
            };
            chat.append(Kind::User, &text).unwrap();
            assert!(chat.wait_idle(None, WAIT));
        }
        chat.render_view()
    };
    let chat = open(dir.path(), 6_000, instant(300));
    assert_eq!(chat.loaded(), Loaded::Resumed);
    assert!(chat.wait_idle(None, WAIT));
    assert_eq!(chat.render_view(), live);
    assert_eq!(chat.status().messages, 700);
    // It goes on: new messages are summarized and the view stays in budget.
    for n in 700..900 {
        chat.append(Kind::Talk, &format!("after {n}")).unwrap();
    }
    assert!(chat.wait_idle(None, WAIT));
    // Spec 3.2: past the budget only by lines built since the last message.
    assert!(chat.status().view_size <= 6_000 + 512);
}

/// Spec 3.2 (gist 3c190e0): the view is saved at every message and loaded at
/// start, never rebuilt from the log (a rebuilt view differs from the live
/// one, and every cache entry dies). A crash without a shutdown resumes the
/// exact live view, also when the start is long after an old checkpoint.
#[test]
fn a_crash_resumes_the_live_view_saved_at_the_last_message() {
    let dir = tempfile::tempdir().unwrap();
    let live = {
        let chat = open(dir.path(), 6_000, instant(300));
        for n in 0..300 {
            chat.append(Kind::User, &format!("m {n} {}", "w ".repeat(n % 40)))
                .unwrap();
            // Appended faster than the compactor builds, now and then: the
            // live view then differs from any fold of the log.
            if n % 7 == 0 {
                assert!(chat.wait_idle(None, WAIT));
            }
        }
        assert!(chat.wait_idle(None, WAIT));
        let view = chat.render_view();
        // A crash: no shutdown.
        std::mem::forget(chat);
        view
    };
    // The forgotten chat still holds its lock socket in this process (a
    // crashed process would not), so reach the database through another
    // chat directory.
    let config = Config {
        db: Some(dir.path().join(DB_FILE)),
        ..config(6_000).0
    };
    let chat = OptChat::open_with(dir.path().join("a"), config, instant(300), Arc::new(SystemClock))
        .unwrap();
    assert_eq!(chat.loaded(), Loaded::Resumed);
    assert!(chat.wait_idle(None, WAIT));
    assert_eq!(chat.render_view(), live);
}

/// A checkpoint thousands of messages behind (written by an older build that
/// saved every 256 messages, then an import) is still resumed: its view is
/// kept and the messages after it are appended, never a fold from message 0.
#[test]
fn a_checkpoint_far_behind_is_resumed_not_folded() {
    let dir = tempfile::tempdir().unwrap();
    let (old, key) = {
        let chat = open(dir.path(), 6_000, instant(300));
        for n in 0..100 {
            chat.append(Kind::User, &format!("early {n}")).unwrap();
        }
        assert!(chat.wait_idle(None, WAIT));
        let key = optchat_host::db::checkpoint::CHECKPOINT_KEY;
        let old = chat.state(key).unwrap().unwrap();
        for n in 0..5_000 {
            chat.append(Kind::Talk, &format!("later {n}")).unwrap();
        }
        assert!(chat.wait_idle(None, WAIT));
        chat.put_state(&[(key.into(), Some(old.clone()))]).unwrap();
        // A crash: no shutdown, so the old checkpoint stays.
        std::mem::forget(chat);
        (old, key)
    };
    let config = Config {
        db: Some(dir.path().join(DB_FILE)),
        ..config(6_000).0
    };
    let chat = OptChat::open_with(dir.path().join("a"), config, instant(300), Arc::new(SystemClock))
        .unwrap();
    assert_eq!(chat.loaded(), Loaded::Resumed);
    assert_ne!(chat.state(key).unwrap().unwrap(), old, "saved again at start");
    assert_eq!(chat.status().messages, 5_100);
}

const CHILD: &str = "OPTCHAT_START_CHILD";

fn rss_kb() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .unwrap_or_default()
        .lines()
        .find_map(|l| l.strip_prefix("VmRSS:"))
        .and_then(|v| v.trim().trim_end_matches("kB").trim().parse().ok())
        .unwrap_or(0)
}

/// One million messages and every node of their tree, written straight
/// into the database (as a migrated home holds them), then opened once so
/// the checkpoint exists, as after the first start.
fn million(dir: &Path) {
    let t: u64 = 1_000_000;
    {
        let chat = open(dir, VIEW_BUDGET, instant(200));
        chat.shutdown();
    }
    let mut conn = rusqlite::Connection::open(dir.join(DB_FILE)).unwrap();
    let tx = conn.transaction().unwrap();
    {
        let mut m = tx
            .prepare("INSERT INTO messages (id, kind, date, day, text) VALUES (?1, ?2, ?3, ?4, ?5)")
            .unwrap();
        for i in 0..t {
            let text = format!("message {i}: {}", "lorem ipsum dolor sit amet ".repeat(7));
            m.execute(rusqlite::params![
                i as i64,
                "user",
                "2026-10-06T12:00:00.000+00:00",
                "2026-10-06",
                text
            ])
            .unwrap();
        }
        let mut n = tx
            .prepare("INSERT INTO nodes (level, idx, bytes, day, text) VALUES (?1, ?2, ?3, ?4, ?5)")
            .unwrap();
        let mut l = 0u32;
        while (1u64 << l) <= t {
            for i in 0..(t >> l) {
                let text = format!("summary {l}+{i}: {}", "consectetur adipiscing ".repeat(5));
                n.execute(rusqlite::params![
                    l as i64,
                    i as i64,
                    text.len() as i64,
                    "2026-10-06",
                    text
                ])
                .unwrap();
            }
            l += 1;
        }
    }
    tx.commit().unwrap();
    drop(conn);
    let chat = open(dir, VIEW_BUDGET, instant(200));
    assert_eq!(chat.status().messages, t);
    chat.shutdown();
}

const VIEW_BUDGET: usize = 128_000;

#[test]
#[ignore = "builds a 1M-message memory (about a minute): run with --ignored"]
fn a_million_message_memory_opens_in_under_half_a_second() {
    if let Ok(dir) = std::env::var(CHILD) {
        let rss0 = rss_kb();
        let started = Instant::now();
        let chat = open(Path::new(&dir), VIEW_BUDGET, instant(200));
        let ms = started.elapsed().as_millis();
        let status = chat.status();
        println!(
            "START {{\"open_ms\": {ms}, \"rss_kb\": {}, \"rss_delta_kb\": {}, \"messages\": {}, \"view_lines\": {}, \"resumed\": {}}}",
            rss_kb(),
            rss_kb().saturating_sub(rss0),
            status.messages,
            status.view_lines,
            chat.loaded() == Loaded::Resumed
        );
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    million(dir.path());
    let out = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "a_million_message_memory_opens_in_under_half_a_second",
            "--ignored",
            "--nocapture",
        ])
        .env(CHILD, dir.path())
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    let line = text
        .lines()
        .find_map(|l| l.find("START ").map(|k| &l[k + 6..]))
        .unwrap_or_else(|| {
            panic!(
                "no measurement: {text} {}",
                String::from_utf8_lossy(&out.stderr)
            )
        });
    println!("{line}");
    let v: serde_json::Value = serde_json::from_str(line).unwrap();
    assert_eq!(v["messages"], 1_000_000);
    assert_eq!(v["resumed"], true);
    assert!(v["open_ms"].as_u64().unwrap() < 500, "{line}");
    assert!(v["rss_kb"].as_u64().unwrap() < 48 * 1024, "{line}");
}
