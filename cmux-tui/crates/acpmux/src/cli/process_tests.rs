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
    assert_eq!(found.get_str("id").unwrap_or(""), "chat-1/task-b7x-2");
    assert_eq!(
        find_process(&list, Some("chat-2/x"), None, None).unwrap().get_str("id").unwrap_or(""),
        "chat-2/x"
    );
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

/// A Claude Monitor an agent named "hold" (`sleep 840; echo t`): the view
/// says it only waits and then wakes the agent, under its
/// command and the agent's name for it; the tab reads "Waiting 14m · hold".
#[test]
fn a_timer_says_what_it_waits_for() {
    let mut p = proc("running");
    p["command"] = json!("sleep 840; echo t");
    p["description"] = json!("hold");
    let h = header(&p, PLAIN);
    assert_eq!(h.lines().next(), Some("$ sleep 840; echo t"));
    assert!(h.contains("named    hold"), "{h}");
    assert!(h.contains("waits    14m, then wakes the agent; it runs nothing else\n"), "{h}");
    assert_eq!(title(&p), "Waiting 14m · hold");
    // The name alone (an older registry knew only it) is not said twice.
    p["command"] = json!("hold");
    let h = header(&p, PLAIN);
    assert!(!h.contains("named"), "{h}");
    assert_eq!(title(&p), "hold");
    // A command with no name keeps its command as the title and no named row.
    assert_eq!(title(&proc("running")), "npm run dev");
    assert!(!header(&proc("running"), PLAIN).contains("named"));
}

#[test]
fn only_a_bare_sleep_reads_as_a_timer() {
    assert_eq!(timer_secs("sleep 840; echo t"), Some(840));
    assert_eq!(timer_secs("sleep 2m && echo done"), Some(120));
    assert_eq!(timer_secs("sleep 1h"), Some(3600));
    assert_eq!(timer_secs("sleep 30; gh pr checks 1"), None);
    assert_eq!(timer_secs("sleep 30; echo $(date)"), None);
    assert_eq!(timer_secs("sleep 30; echo t > f"), None);
    assert_eq!(timer_secs("sleep 30; echo t & make build"), None);
    assert_eq!(timer_secs("sleep x"), None);
    assert_eq!(timer_secs("npm run dev"), None);
    assert_eq!(span(840), "14m");
    assert_eq!(span(45), "45s");
    assert_eq!(span(7200), "2h");
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

fn start(slow: Option<&str>) -> Start {
    Start {
        cwd: None,
        description: Some("dev server".to_owned()),
        notify: true,
        route: Some("code-mode".to_owned()),
        slow: slow.map(str::to_owned),
        command: "npm run dev".to_owned(),
    }
}

/// `process start` (the Bash hook's rewrite, `bg_hook::decide`) starts the task in the chat its
/// environment names, in the shell's own folder, for the subagent the hook's mark names.
#[test]
fn process_start_asks_for_the_chats_task_in_the_shells_folder() {
    let env = |k: &str| match k {
        "ACPMUX_SESSION_ID" => Some("chat-1".to_owned()),
        "ACPMUX_CALLER_SUBAGENT" => Some("Explore:a0a68e7af3df5967e".to_owned()),
        _ => None,
    };
    let params = start_params(&start(None), &env, Some("/srv/app".into())).unwrap();
    assert_eq!(
        params,
        json!({"sessionId": "chat-1", "command": "npm run dev", "notify": true,
            "cwd": "/srv/app", "description": "dev server",
            "callerSubagent": {"id": "a0a68e7af3df5967e", "type": "Explore"}})
    );
    // --cwd wins; an odd mark names no subagent.
    let mut s = start(None);
    s.cwd = Some("/elsewhere".to_owned());
    let odd = |k: &str| match k {
        "ACPMUX_SESSION_ID" => Some("chat-1".to_owned()),
        "ACPMUX_CALLER_SUBAGENT" => Some("x:a1;rm -rf /".to_owned()),
        _ => None,
    };
    let params = start_params(&s, &odd, Some("/srv/app".into())).unwrap();
    assert_eq!(params["cwd"], "/elsewhere");
    assert!(params.get("callerSubagent").is_none(), "{params}");
    // Outside a chat: no task.
    assert!(start_params(&start(None), &|_: &str| None, None).is_err());
}

/// What the agent reads back: the id, that it outlives hibernation, the chat's own call that
/// reads it, and for a moved foreground command why and how to keep it in the foreground.
#[test]
fn process_start_answers_with_the_id_and_how_to_read_it() {
    let view = json!({"id": "t7", "state": "running", "command": "npm run dev",
        "description": "dev server"});
    let text = started_text(&start(None), &view);
    assert!(text.contains("background task t7"), "{text}");
    assert!(text.contains("keeps running while this chat's agent hibernates"), "{text}");
    assert!(text.contains(r#"cmux.acpmux_bg_output({"id":"t7"})"#), "{text}");
    assert!(!text.contains("# fg-ok"), "{text}");
    let text = started_text(&start(Some("a follow that never ends on its own")), &view);
    assert!(text.contains("This is a follow that never ends on its own"), "{text}");
    assert!(text.contains("# fg-ok"), "{text}");
}

/// A start that failed says the same call again runs as asked (the hook's key stays); one that
/// started forgets the key, so the same call later is rewritten again.
#[cfg(unix)]
#[test]
fn process_start_forgets_the_hooks_key_only_once_started() {
    let dir = tempfile::tempdir().unwrap();
    let denied = dir.path().join("mcp.json.bg-denied");
    std::fs::write(&denied, "k1\nk2\n").unwrap();
    let hook = || Some((denied.clone(), "k1".to_owned()));
    let failed = |sent| Err(StartFailed { sent, error: anyhow!("no daemon") });
    let err = finish_start(&start(None), failed(false), hook(), true).unwrap_err();
    assert!(err.to_string().contains("Send the same Bash call again"), "{err}");
    assert_eq!(std::fs::read_to_string(&denied).unwrap(), "k1\nk2\n");
    // Sent but unanswered: the task may run, so never "send it again and it runs".
    let err = finish_start(&start(None), failed(true), hook(), true).unwrap_err();
    assert!(err.to_string().contains("look in bg_list"), "{err}");
    assert!(!err.to_string().contains("Send the same Bash call again"), "{err}");
    finish_start(&start(None), Ok(json!({"id": "t7", "state": "running"})), hook(), true).unwrap();
    assert_eq!(std::fs::read_to_string(&denied).unwrap(), "k2\n");
}
