//! `acpmux process show` (cli/process.rs): which process a click names, what
//! the header and footer say, and the replay of every byte it printed.

use super::*;
use std::cell::RefCell;
use std::time::Duration;

fn proc(state: &str) -> Value {
    json!({
        "id": "chat-1/task-b7x",
        "sessionId": "chat-1",
        "subagentSessionId": null,
        "toolCallId": "toolu_1",
        "taskId": "task-b7x",
        "harness": "claude",
        "command": "npm run dev",
        "cwd": "/srv/uploader",
        "startedAt": 1_000_000u64,
        "endedAt": null,
        "state": state,
        "origin": "background",
        "outputFile": "/srv/tasks/b7x.output",
    })
}

/// One page of output a stand-in daemon serves.
fn page(data: &[u8], eof: bool) -> (Vec<u8>, bool) {
    (data.to_vec(), eof)
}

const PLAIN: Style = Style { color: false, terminal: false };

/// A process's output as a stand-in daemon serves it: `pages[i]` is what
/// the i-th read returns (an empty page while nothing new came).
struct Fake {
    pages: RefCell<Vec<(Vec<u8>, bool)>>,
    reads: RefCell<Vec<u64>>,
    record: RefCell<Value>,
    killed: RefCell<Vec<String>>,
    unsupported: bool,
}

impl Fake {
    fn new(pages: Vec<(Vec<u8>, bool)>, record: Value) -> Fake {
        Fake {
            pages: RefCell::new(pages),
            reads: RefCell::new(Vec::new()),
            record: RefCell::new(record),
            killed: RefCell::new(Vec::new()),
            unsupported: false,
        }
    }
}

impl Source for Fake {
    async fn tail(&self, id: &str, from: u64) -> Result<Chunk, TailError> {
        assert_eq!(id, "chat-1/task-b7x");
        self.reads.borrow_mut().push(from);
        if self.unsupported {
            return Err(TailError::Unsupported);
        }
        let mut pages = self.pages.borrow_mut();
        let (data, eof) = if pages.is_empty() { (Vec::new(), false) } else { pages.remove(0) };
        Ok(Chunk { next: from + data.len() as u64, eof, data })
    }
    async fn get(&self, _id: &str) -> Result<Option<Value>> {
        Ok(Some(self.record.borrow().clone()))
    }
    async fn kill(&self, id: &str) -> Result<()> {
        self.killed.borrow_mut().push(id.to_owned());
        self.record.borrow_mut()["state"] = json!("killed");
        self.pages.borrow_mut().push((b"^C\n".to_vec(), true));
        Ok(())
    }
}

fn opts(follow: bool, interactive: bool) -> ReplayOpts {
    ReplayOpts {
        follow,
        interactive,
        pause_min: Duration::from_millis(1),
        pause_max: Duration::from_millis(2),
    }
}

#[test]
fn a_click_finds_the_latest_process_its_tool_call_started() {
    let mut older = proc("exited");
    older["id"] = json!("chat-1/task-b7x");
    let mut newer = proc("running");
    newer["id"] = json!("chat-1/task-b7x-2");
    newer["startedAt"] = json!(2_000_000u64);
    let mut other = proc("running");
    other["id"] = json!("chat-2/x");
    other["sessionId"] = json!("chat-2");
    let list = vec![older, newer, other];
    let found = find_process(&list, None, Some("chat-1"), Some("toolu_1")).unwrap();
    assert_eq!(text(found, "id"), "chat-1/task-b7x-2");
    assert_eq!(text(find_process(&list, Some("chat-2/x"), None, None).unwrap(), "id"), "chat-2/x");
    assert!(find_process(&list, None, Some("chat-9"), Some("toolu_1")).is_none());
}

#[test]
fn a_subagents_process_is_found_from_the_subagents_chat() {
    let mut p = proc("running");
    p["subagentSessionId"] = json!("sub-7");
    let list = vec![p];
    assert!(find_process(&list, None, Some("sub-7"), Some("toolu_1")).is_some());
}

#[test]
fn the_header_names_the_command_folder_start_and_output_file() {
    let h = header(&proc("running"), PLAIN);
    let lines: Vec<&str> = h.lines().collect();
    assert_eq!(lines[0], "$ npm run dev");
    assert!(h.contains("folder   /srv/uploader"), "{h}");
    assert!(h.contains("Claude Code · background"), "{h}");
    assert!(h.contains("log      /srv/tasks/b7x.output"), "{h}");
    assert!(lines.last().unwrap().starts_with('─'), "{h}");
}

#[test]
fn the_footer_says_how_it_ended_and_after_how_long() {
    let at = |state: &str, extra: Value| {
        let mut p = proc(state);
        p["endedAt"] = json!(1_000_000u64 + 192_000);
        for (k, v) in extra.as_object().unwrap() {
            p[k] = v.clone();
        }
        footer(&p, 0, PLAIN, Outcome::Ended)
    };
    assert!(at("exited", json!({})).contains("✓ Completed after 3m 12s"));
    assert!(at("exited", json!({"exitCode": 2})).contains("✗ Failed (exit 2) after 3m 12s"));
    assert!(at("failed", json!({})).contains("✗ Failed after 3m 12s"));
    assert!(at("killed", json!({"reason": "person"})).contains("■ Stopped by you after 3m 12s"));
    assert!(at("killed", json!({"reason": "agent"})).contains("■ Stopped by the agent"));
    assert!(at("lost", json!({})).contains("? Lost: its agent exited"));
    let detail = at("exited", json!({"detail": "Tests passed"}));
    assert!(detail.contains("  Tests passed"), "{detail}");
    let running = footer(&proc("running"), 1_000_000 + 4_000, PLAIN, Outcome::Snapshot);
    assert!(running.contains("● Running for 4s"), "{running}");
}

#[test]
fn a_terminal_gets_carriage_returns() {
    let h = header(&proc("running"), Style { color: false, terminal: true });
    assert!(h.contains("$ npm run dev\r\n"));
    assert!(!h.replace("\r\n", "").contains('\n'));
}

#[test]
fn durations_read_as_a_person_says_them() {
    assert_eq!(human(450), "450ms");
    assert_eq!(human(4_000), "4s");
    assert_eq!(human(192_000), "3m 12s");
    assert_eq!(human(7_500_000), "2h 05m");
}

#[tokio::test]
async fn every_byte_is_replayed_raw_from_the_first_one() {
    let colored: &[u8] = b"\x1b[32mready\x1b[0m on :3000\n";
    let fake = Fake::new(
        vec![page(b"> uploader@1 dev\n", false), page(colored, false), page(b"", true)],
        proc("exited"),
    );
    let (_tx, mut rx) = mpsc::channel(1);
    let mut out = Vec::new();
    let outcome =
        replay(&fake, &proc("exited"), &mut out, opts(false, false), &mut rx).await.unwrap();
    assert_eq!(outcome, Outcome::Ended);
    let mut want = b"> uploader@1 dev\n".to_vec();
    want.extend_from_slice(colored);
    assert_eq!(out, want);
    assert_eq!(*fake.reads.borrow(), vec![0, 17, 17 + colored.len() as u64]);
}

#[tokio::test]
async fn without_follow_it_stops_at_what_was_printed_so_far() {
    let fake = Fake::new(
        vec![page(b"a\n", false), page(b"", false), page(b"never\n", true)],
        proc("running"),
    );
    let (_tx, mut rx) = mpsc::channel(1);
    let mut out = Vec::new();
    let outcome =
        replay(&fake, &proc("running"), &mut out, opts(false, false), &mut rx).await.unwrap();
    assert_eq!(outcome, Outcome::Snapshot);
    assert_eq!(out, b"a\n");
}

#[tokio::test]
async fn follow_keeps_reading_while_nothing_comes_until_it_ends() {
    let fake = Fake::new(
        vec![
            page(b"one\n", false),
            page(b"", false),
            page(b"", false),
            page(b"two\n", false),
            page(b"", true),
        ],
        proc("running"),
    );
    let (_tx, mut rx) = mpsc::channel(1);
    let mut out = Vec::new();
    let outcome =
        replay(&fake, &proc("running"), &mut out, opts(true, false), &mut rx).await.unwrap();
    assert_eq!(outcome, Outcome::Ended);
    assert_eq!(out, b"one\ntwo\n");
}

#[tokio::test]
async fn q_closes_the_view_and_leaves_the_process_running() {
    let fake = Fake::new(vec![page(b"serving\n", false)], proc("running"));
    let (tx, mut rx) = mpsc::channel(4);
    tx.send(Input::Quit).await.unwrap();
    let mut out = Vec::new();
    let outcome =
        replay(&fake, &proc("running"), &mut out, opts(true, true), &mut rx).await.unwrap();
    assert_eq!(outcome, Outcome::Closed);
    assert!(fake.killed.borrow().is_empty());
}

#[tokio::test]
async fn k_then_y_stops_the_process_and_the_view_shows_its_end() {
    let fake = Fake::new(vec![page(b"serving\n", false)], proc("running"));
    let (tx, mut rx) = mpsc::channel(4);
    tx.send(Input::Kill).await.unwrap();
    tx.send(Input::Yes).await.unwrap();
    let mut out = Vec::new();
    let outcome =
        replay(&fake, &proc("running"), &mut out, opts(true, true), &mut rx).await.unwrap();
    assert_eq!(outcome, Outcome::Ended);
    assert_eq!(*fake.killed.borrow(), vec!["chat-1/task-b7x".to_owned()]);
    let shown = String::from_utf8(out).unwrap();
    assert!(shown.contains("Stop this process? [y/N]"), "{shown}");
    assert!(shown.ends_with("^C\n"), "{shown}");
}

#[tokio::test]
async fn k_then_n_keeps_it_running() {
    let fake = Fake::new(vec![page(b"serving\n", false)], proc("running"));
    let (tx, mut rx) = mpsc::channel(4);
    tx.send(Input::Kill).await.unwrap();
    tx.send(Input::No).await.unwrap();
    tx.send(Input::Quit).await.unwrap();
    let mut out = Vec::new();
    let outcome =
        replay(&fake, &proc("running"), &mut out, opts(true, true), &mut rx).await.unwrap();
    assert_eq!(outcome, Outcome::Closed);
    assert!(fake.killed.borrow().is_empty());
}

#[tokio::test]
async fn a_process_whose_agent_shares_no_output_says_so_and_ends_with_it() {
    let mut fake = Fake::new(vec![], proc("exited"));
    fake.unsupported = true;
    let (_tx, mut rx) = mpsc::channel(1);
    let mut out = Vec::new();
    let outcome =
        replay(&fake, &proc("running"), &mut out, opts(true, false), &mut rx).await.unwrap();
    assert_eq!(outcome, Outcome::Ended);
    assert!(String::from_utf8(out).unwrap().contains("does not share"));
}

#[test]
fn keys_map_to_what_the_viewer_does() {
    assert_eq!(Input::of(b'q'), Some(Input::Quit));
    assert_eq!(Input::of(0x03), Some(Input::Quit));
    assert_eq!(Input::of(b'k'), Some(Input::Kill));
    assert_eq!(Input::of(b'y'), Some(Input::Yes));
    assert_eq!(Input::of(b'\r'), Some(Input::No));
    assert_eq!(Input::of(b'x'), None);
}
