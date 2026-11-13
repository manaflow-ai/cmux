//! `Filter`: what the watch's callback hands on, by the roots' adapters. `coalesce`: what the
//! chat watch thread makes of it, driven through a scripted `Source` (no file system, no clock,
//! no sleep).

use super::*;
use std::collections::VecDeque;

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

fn paths<S: AsRef<str>>(list: &[S]) -> Vec<PathBuf> {
    list.iter().map(|path| PathBuf::from(path.as_ref())).collect()
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
        assert!(f.handed_from_notify(modify(&[path])).is_none(), "{path}");
        assert!(f.handed_from_delivery(paths(&[path]), false).is_none(), "{path}");
    }
    let open =
        notify::EventKind::Access(notify::event::AccessKind::Open(notify::event::AccessMode::Any));
    assert!(
        f.handed_from_notify(event(open, &["/h/.claude/projects/-work/0199c0de.jsonl"])).is_none()
    );
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
        assert!(f.handed_from_notify(modify(&[path])).is_some(), "{path}");
        assert!(f.handed_from_delivery(paths(&[path]), false).is_some(), "{path}");
    }
    // One path the index reads among others: only that one is handed on.
    let mixed = f.handed_from_delivery(
        paths(&["/h/.codex/log/x.log", "/h/.claude/projects/-w/0199c0de.jsonl"]),
        false,
    );
    assert!(
        matches!(&mixed, Some(Message::Paths { paths: p, rescan: false })
            if p == &paths(&["/h/.claude/projects/-w/0199c0de.jsonl"])),
        "{mixed:?}"
    );
    // A watcher error or a rescan may have dropped events: always handed on.
    assert!(matches!(
        f.handed_from_notify(Err(notify::Error::generic("dropped"))),
        Some(Message::Paths { rescan: true, .. })
    ));
    let rescan = notify::Event::new(notify::EventKind::Other)
        .set_flag(notify::event::Flag::Rescan)
        .add_path("/h/.codex/log".into());
    assert!(matches!(f.handed_from_notify(Ok(rescan)), Some(Message::Paths { rescan: true, .. })));
    assert!(matches!(
        f.handed_from_delivery(paths(&["/h/.codex/log/x.log"]), true),
        Some(Message::Paths { rescan: true, .. })
    ));
}

/// A scripted source: each message at its time after the start; the clock moves only to the
/// next message or to the deadline asked for.
struct Script {
    start: Instant,
    now: Instant,
    items: VecDeque<(Duration, Message)>,
}

impl Script {
    fn new(items: Vec<(Duration, Message)>) -> Self {
        let start = Instant::now();
        Self { start, now: start, items: items.into() }
    }
}

impl Source for Script {
    fn now(&self) -> Instant {
        self.now
    }

    fn next(&mut self, until: Option<Instant>) -> Next {
        let due =
            self.items.front().is_some_and(|(at, _)| until.is_none_or(|u| self.start + *at <= u));
        if due && let Some((at, message)) = self.items.pop_front() {
            self.now = self.now.max(self.start + at);
            return Next::Message(message);
        }
        match until {
            Some(until) => {
                self.now = until;
                Next::Timeout
            }
            None => Next::Closed,
        }
    }
}

const ROOT: &str = "/h/.claude/projects";

fn session(project: usize, n: usize) -> String {
    format!("{ROOT}/-p{project}/00000000-0000-4000-8000-{n:012}.jsonl")
}

/// The messages the watch's callback hands on for `changed` (one delivery each).
fn delivered(f: &Filter, at: Duration, changed: &[String]) -> Option<(Duration, Message)> {
    let changed = changed.iter().map(PathBuf::from).collect();
    f.handed_from_delivery(changed, false).map(|message| (at, message))
}

fn bursts(script: Vec<(Duration, Message)>) -> Vec<Burst> {
    let mut out = Vec::new();
    coalesce(&mut Script::new(script), |burst| {
        out.push(burst);
        true
    });
    out
}

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

/// 170 sessions written within one quiet window, with their subagents' transcripts and tools'
/// results among them: one index pass, which holds every session once and nothing else.
#[test]
fn changes_within_one_quiet_window_reach_the_index_as_one_pass() {
    let f = filter();
    let mut script = Vec::new();
    for n in 0..170 {
        let at = ms(n as u64);
        let noise = format!("{ROOT}/-p{}/s{n}/subagents/agent-a{n}.jsonl", n % 40);
        let tool = format!("{ROOT}/-p{}/s{n}/tool-results/toolu_{n}.txt", n % 40);
        script.extend(delivered(&f, at, &[noise, tool]));
        script.extend(delivered(&f, at, &[session(n % 40, n), session(n % 40, n)]));
    }
    let got = bursts(script);
    assert_eq!(got.len(), 1, "{got:?}");
    let want: Vec<PathBuf> = (0..170).map(|n| PathBuf::from(session(n % 40, n))).collect();
    assert_eq!(got[0].paths, want);
    assert!(!got[0].rescan);
}

/// Changes at the edges of a burst: one exactly when the quiet window ends, one exactly at the
/// longest burst, and a steady stream past it. Every change reaches the index in exactly one
/// pass; none is lost and none is read twice.
#[test]
fn a_change_at_the_edge_of_a_window_is_not_lost() {
    let f = filter();
    let mut script = Vec::new();
    let mut sent = Vec::new();
    let mut at = Duration::ZERO;
    let mut push = |at: Duration, n: usize, script: &mut Vec<(Duration, Message)>| {
        sent.push(PathBuf::from(session(0, n)));
        script.extend(delivered(&f, at, &[session(0, n)]));
    };
    // A burst whose last change comes exactly QUIET after the one before it.
    push(at, 0, &mut script);
    at += QUIET;
    push(at, 1, &mut script);
    // A quiet gap, then a stream every 100 ms for 3 s: it passes MAX_BURST, and one change
    // lands exactly on it.
    at += QUIET * 4;
    let stream_start = at;
    for n in 2..32 {
        push(at, n, &mut script);
        at += ms(100);
    }
    script.sort_by_key(|(at, _)| *at);
    assert!(script.iter().any(|(at, _)| *at == stream_start + MAX_BURST));
    let got = bursts(script);
    let mut all: Vec<PathBuf> = got.iter().flat_map(|b| b.paths.clone()).collect();
    assert_eq!(all.len(), sent.len(), "a change was read twice or lost: {got:?}");
    all.sort();
    sent.sort();
    assert_eq!(all, sent);
    // The change exactly QUIET after the first joined its burst; the stream was cut at MAX_BURST.
    assert_eq!(got[0].paths, paths(&[&session(0, 0), &session(0, 1)]), "{got:?}");
    assert_eq!(got.len(), 3, "{got:?}");
}

/// During a burst of subagent writes, a new project folder is made with a new session in it:
/// the session file reaches the index in that burst. A delivery that lost events (FSEvents
/// MustScanSubDirs) makes the pass a scan.
#[test]
fn a_session_folder_made_during_a_burst_is_seen() {
    let f = filter();
    let new_folder = format!("{ROOT}/-new-project");
    let new_session = format!("{new_folder}/0199c0de-0000-4000-8000-000000000001.jsonl");
    let mut script = Vec::new();
    for n in 0..20u64 {
        let noise = format!("{ROOT}/-p1/s1/subagents/agent-a{n}.jsonl");
        script.extend(delivered(&f, ms(n * 10), &[noise]));
    }
    // The folder and its first session come in one delivery mid-burst, as FSEvents sends them.
    script.extend(delivered(&f, ms(105), &[new_folder.clone(), new_session.clone()]));
    let got = bursts(script);
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!(got[0].paths, paths(&[&new_session]));

    let lost = f.handed_from_delivery(paths(&[&format!("{ROOT}/-p1/s1/subagents/a.jsonl")]), true);
    let got = bursts(vec![(Duration::ZERO, lost.expect("a lost-events delivery is handed on"))]);
    assert!(got[0].rescan, "{got:?}");
}

/// A Stop ends the thread's loop, also in the middle of a burst.
#[test]
fn a_stop_ends_the_loop() {
    let f = filter();
    let mut script: Vec<_> = delivered(&f, ms(0), &[session(0, 0)]).into_iter().collect();
    script.push((ms(10), Message::Stop));
    script.extend(delivered(&f, ms(20), &[session(0, 1)]));
    assert!(bursts(script).is_empty());
}

/// notify watches a folder made in a tree only after it handed on the event that made it: such
/// a folder, made or moved in, is handed on to be listed, whether or not its path is one the
/// index reads; a folder outside every root, a root itself and a file are not.
#[cfg(not(target_os = "macos"))]
#[test]
fn a_folder_made_in_a_root_is_handed_on_to_be_listed() {
    use notify::event::{CreateKind, ModifyKind, RenameMode};
    let f = filter();
    let made = notify::EventKind::Create(CreateKind::Folder);
    for path in ["/h/.codex/sessions", "/h/.codex/sessions/2026/11/12", "/h/.claude/projects/-w"] {
        let got = f.handed_from_notify(event(made, &[path]));
        assert!(matches!(&got, Some(Message::Folder(p)) if p == Path::new(path)), "{got:?}");
    }
    assert!(f.handed_from_notify(event(made, &["/elsewhere/sessions"])).is_none());
    // A Codex home's other folders hold no chat: they end in the callback.
    for path in ["/h/.codex/log", "/h/.codex/worktrees/x/src"] {
        assert!(f.handed_from_notify(event(made, &[path])).is_none(), "{path}");
    }
    // A root made again is a path, as before: the index scans it.
    let root = f.handed_from_notify(event(made, &["/h/.codex"]));
    assert!(matches!(&root, Some(Message::Paths { .. })), "{root:?}");
    let file = notify::EventKind::Create(CreateKind::File);
    let rollout = "/h/.codex/sessions/2026/11/12/rollout-2026-11-12T00-00-00-x.jsonl";
    assert!(matches!(f.handed_from_notify(event(file, &[rollout])), Some(Message::Paths { .. })));
    // A path moved in names no kind: a folder only when it is one (this one does not exist).
    let moved = notify::EventKind::Modify(ModifyKind::Name(RenameMode::To));
    assert!(matches!(f.handed_from_notify(event(moved, &[rollout])), Some(Message::Paths { .. })));
    // Each folder once per burst, and none below another (its listing covers them), in either
    // order.
    let script = vec![
        (ms(0), Message::Folder("/h/.codex/sessions/2026".into())),
        (ms(5), Message::Folder("/h/.codex/sessions".into())),
        (ms(10), Message::Folder("/h/.codex/sessions/2026/11".into())),
        (ms(15), Message::Folder("/h/.codex/sessions".into())),
        (ms(20), Message::Folder("/h/.claude/projects/-w".into())),
    ];
    let got = bursts(script);
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!(got[0].folders, paths(&["/h/.codex/sessions", "/h/.claude/projects/-w"]));
}
