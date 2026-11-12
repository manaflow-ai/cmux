//! `Filter`: what the watch's callback hands on, by the roots' adapters.

use super::*;

fn event(kind: notify::EventKind, paths: &[&str]) -> notify::Result<notify::Event> {
    let mut event = notify::Event::new(kind);
    for path in paths {
        event = event.add_path(PathBuf::from(path));
    }
    Ok(event)
}

fn modify(paths: &[&str]) -> notify::Result<notify::Event> {
    event(notify::EventKind::Modify(notify::event::ModifyKind::Any), paths)
}

fn filter() -> Filter {
    Filter {
        roots: vec![
            WatchedRoot { path: "/h/.codex".into(), kind: AdapterKind::Codex },
            WatchedRoot { path: "/h/.claude/projects".into(), kind: AdapterKind::ClaudeCode },
        ],
    }
}

#[test]
fn files_that_hold_no_chat_end_in_the_callback() {
    let f = filter();
    for path in [
        "/h/.codex/logs_2.sqlite-wal",
        "/h/.codex/history.jsonl",
        "/h/.codex/state_5.sqlite-shm",
        "/h/.codex/log/codex-tui.log",
        "/h/.claude/projects/-work/0199c0de/subagents/agent-a1.jsonl",
        "/h/.claude/projects/-work/0199c0de/tool-results/toolu_01.txt",
        "/h/.claude/projects/-work",
        "/elsewhere/rollout-x.jsonl",
    ] {
        assert!(!f.needed(&modify(&[path])), "{path}");
    }
    let open =
        notify::EventKind::Access(notify::event::AccessKind::Open(notify::event::AccessMode::Any));
    assert!(!f.needed(&event(open, &["/h/.claude/projects/-work/0199c0de.jsonl"])));
}

#[test]
fn files_the_index_reads_and_the_roots_themselves_are_handed_on() {
    let f = filter();
    for path in [
        "/h/.codex/sessions/2026/11/12/rollout-2026-11-12T00-00-00-x.jsonl",
        "/h/.codex/archived_sessions/rollout-2026-01-01T00-00-00-x.jsonl",
        "/h/.codex/state_5.sqlite-wal",
        "/h/.codex/session_index.jsonl",
        "/h/.claude/projects/-work/0199c0de.jsonl",
        "/h/.claude/projects/-work/0199c0de/custom-title.json",
        "/h/.codex",
        "/h/.claude/projects",
    ] {
        assert!(f.needed(&modify(&[path])), "{path}");
    }
    // One path the index reads among others is enough.
    assert!(f.needed(&modify(&["/h/.codex/log/x.log", "/h/.claude/projects/-w/0199c0de.jsonl"])));
    // A watcher error or a rescan may have dropped events: always handed on.
    assert!(f.needed(&Err(notify::Error::generic("dropped"))));
    let rescan = notify::Event::new(notify::EventKind::Other)
        .set_flag(notify::event::Flag::Rescan)
        .add_path("/h/.codex/log".into());
    assert!(f.needed(&Ok(rescan)));
}
