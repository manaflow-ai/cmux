//! The Chief's turn tools (plans/cmux-next/chief-tools-DESIGN.md; the user,
//! 2026-10-20: "you probably should have replied twice separately to the two
//! different messages ... a `send message` tool ... a `stop` tool call ...
//! another tool called `sleep`"): `send` posts one message now (text, files,
//! a thread), `stop` ends the turn with no final text, `sleep` ends it and
//! wakes the Chief later.

mod common;

use std::sync::Arc;
use std::time::Duration;

use cmux_conversation::{Op, Part, PartRef};
use common::*;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{Call, Orchestrator, SendCall, SleepCall};
use serde_json::json;

fn spawner(h: &Harness) -> Arc<Spawner> {
    Arc::new(Spawner::new(
        h.chat.clone(),
        h.agents.clone(),
        SubagentSettings {
            harness: "claude".into(),
            policy: "approve-all".into(),
            model: None,
            effort: None,
            preset: Some("optchat-sub-h0me".into()),
            cwd: h.dir.path().join("subagent"),
            prefix: "optchat-sub-h0me".into(),
            parent: optchat_chief::brain::PARENT.into(),
            claude_md: None,
        },
        h.tx.clone(),
        Arc::new(|_: &str| {}),
    ))
}

/// Runs `f` on its own thread while the brain takes its inputs.
fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    worker.join().unwrap()
}

/// One `message.send` the owner took: (key, parts, reply_to, thread_root).
type Sent = (String, Vec<Part>, Option<PartRef>, Option<String>);

/// Every `message.send` the owner took.
fn sends(h: &Harness) -> Vec<Sent> {
    h.owner
        .lock()
        .unwrap()
        .ops
        .iter()
        .filter_map(|(key, op)| match op {
            Op::MessageSend {
                parts,
                reply_to,
                thread_root,
                ..
            } => Some((
                key.clone(),
                parts.clone(),
                reply_to.clone(),
                thread_root.clone(),
            )),
            _ => None,
        })
        .collect()
}

fn texts(parts: &[Part]) -> String {
    parts
        .iter()
        .filter_map(|p| match p {
            Part::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The sends whose text contains `needle`, stepping the brain until one
/// lands (an attachment goes through the upload thread first).
fn wait_send(h: &mut Harness, needle: &str) -> Vec<Sent> {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        let found: Vec<_> = sends(h)
            .into_iter()
            .filter(|(_, parts, _, _)| {
                texts(parts).contains(needle)
                    || parts.iter().any(
                        |p| matches!(p, Part::Attachment { name, .. } if name.contains(needle)),
                    )
            })
            .collect();
        if !found.is_empty() {
            return found;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "no send with {needle:?}: {:?}",
            sends(h)
        );
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
        if let Some(at) = h.brain.next_timer()
            && at <= std::time::Instant::now()
        {
            h.brain.on_timer();
        }
    }
}

/// The default script, except that the first turn never ends by itself: it
/// works until something stops it (here: the Chief's `stop` or `sleep`).
fn endless_first_turn() -> Script {
    let base = default_script();
    Box::new(move |turn, blocks| {
        let mut events = base(turn, blocks);
        if turn == 0 {
            events.pop();
        }
        events
    })
}

/// A turn is running for `text`, held at the fake agent.
fn running(h: &mut Harness, text: &str) {
    h.agents.hold(true);
    h.connect();
    h.say("user_local", text);
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        h.step();
    }
}

fn line_of(h: &Harness, seq: u64) -> u64 {
    h.chat
        .logged_id(&format!("{CONV}#{seq}"))
        .expect("the message is in the log")
}

fn send(text: &str) -> SendCall {
    SendCall {
        sign_in: None,
        text: Some(text.to_owned()),
        attachments: Vec::new(),
        reply_to: None,
    }
}

#[test]
fn turn_tools_send_posts_a_top_level_message_now_and_a_repeat_is_a_noop() {
    let mut h = Harness::new(default_script());
    running(&mut h, "two asks: the build and the docs");
    let sp = spawner(&h);
    let answer = run(&mut h, move || sp.send(send("The build is green."))).expect("send answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    let posted = wait_send(&mut h, "The build is green.");
    assert_eq!(posted.len(), 1, "{posted:?}");
    assert_eq!(posted[0].2, None, "top level: {posted:?}");
    assert_eq!(posted[0].3, None, "top level: {posted:?}");
    let sp = spawner(&h);
    let again = run(&mut h, move || sp.send(send("The build is green."))).expect("send answers");
    assert!(again.starts_with("outcome: noop"), "{again}");
    h.agents.hold(false);
    h.agents.release();
    h.settle_posts();
}

#[test]
fn turn_tools_send_with_reply_to_goes_into_that_messages_thread() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "the build?");
    h.settle_posts();
    let line = line_of(&h, 1);
    let sp = spawner(&h);
    let call = SendCall {
        reply_to: Some(line),
        ..send("Green on every Mac mini.")
    };
    let answer = run(&mut h, move || sp.send(call)).expect("send answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    let posted = wait_send(&mut h, "Green on every Mac mini.");
    assert_eq!(posted[0].3.as_deref(), Some("msg_1"), "{posted:?}");
    assert_eq!(
        posted[0].2.as_ref().map(|r| r.message_id.as_str()),
        Some("msg_1")
    );
}

#[test]
fn turn_tools_send_attaches_any_file_and_refuses_a_missing_one() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "send me the report");
    h.settle_posts();
    let report = h.dir.path().join("REPORT.pdf");
    std::fs::write(&report, b"%PDF-1.4 fake").unwrap();
    let sp = spawner(&h);
    let call = SendCall {
        attachments: vec![report.display().to_string()],
        ..send("Here is the report.")
    };
    let answer = run(&mut h, move || sp.send(call)).expect("send answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    let posted = wait_send(&mut h, "REPORT.pdf");
    let parts = &posted[0].1;
    assert!(
        parts
            .iter()
            .any(|p| matches!(p, Part::Attachment { name, mime_type, .. }
            if name == "REPORT.pdf" && mime_type == "application/pdf")),
        "a pdf attachment part: {parts:?}"
    );
    assert!(texts(parts).contains("Here is the report."), "{parts:?}");

    let missing = h.dir.path().join("nope.png").display().to_string();
    let before = sends(&h).len();
    let sp = spawner(&h);
    let refused = run(&mut h, move || {
        sp.send(SendCall {
            attachments: vec![missing],
            ..send("and the screenshot")
        })
    });
    assert!(refused.is_err(), "{refused:?}");
    assert_eq!(sends(&h).len(), before, "nothing posted");
}

/// The user, 2026-10-26: a screenshot whose upload the owner refused showed
/// in Home as the text "!alarm-fired-100542Z.png". A file that does not
/// upload goes as a link to it (a file chip Home can open), never as image
/// syntax Home will not draw.
#[test]
fn turn_tools_send_a_refused_upload_goes_as_a_file_link() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "send me the screenshot");
    h.settle_posts();
    h.owner.lock().unwrap().refuse_uploads = Some("chunk_too_large".into());
    let shot = h.dir.path().join("alarm-fired.png");
    std::fs::write(&shot, b"\x89PNG fake").unwrap();
    let sp = spawner(&h);
    let call = SendCall {
        attachments: vec![shot.display().to_string()],
        ..send("The test alarm rang.")
    };
    let answer = run(&mut h, move || sp.send(call)).expect("send answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    let posted = wait_send(&mut h, "alarm-fired.png");
    let text = texts(&posted[0].1);
    assert_eq!(
        text,
        format!(
            "The test alarm rang.\n[alarm-fired.png]({})",
            url::Url::from_file_path(&shot).unwrap()
        ),
        "{posted:?}"
    );
}

#[test]
fn turn_tools_stop_ends_the_turn_with_no_final_text_and_no_failure() {
    let mut h = Harness::new(endless_first_turn());
    running(&mut h, "start the work");
    // A person's message gets words before stop (eval_replies.rs).
    let sp = spawner(&h);
    run(&mut h, move || sp.send(send("On it."))).expect("send answers");
    let sp = spawner(&h);
    let answer = run(&mut h, move || sp.stop_turn()).expect("stop answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    h.agents.hold(false);
    h.settle_posts();
    assert!(
        !h.agents.inner.lock().unwrap().cancels.is_empty(),
        "the session was cancelled"
    );
    let all = sends(&h);
    assert!(
        all.iter().all(|(_, parts, _, _)| {
            let t = texts(parts);
            !t.contains("answer") && !t.contains("Checking") && !t.contains("turn failed")
        }),
        "no final text, no failure: {all:?}"
    );
    // The next message runs a normal turn: the stop did not stick.
    h.say("user_local", "and now?");
    h.settle_posts();
    assert!(
        sends(&h)
            .iter()
            .any(|(_, parts, _, _)| texts(parts).contains("answer")),
        "{:?}",
        sends(&h)
    );
}

/// The trace names a turn the Chief ended itself `stopped`, not `cancelled`:
/// counted as a cancel, 611 such turns read as 53% of Lawrence's turns failing
/// (Oct 20-26, chief_health.py).
#[test]
fn turn_tools_a_turn_the_chief_stops_is_traced_as_stopped_not_cancelled() {
    let mut h = Harness::new(endless_first_turn());
    let traces = h.dir.path().join("traces");
    h.brain
        .set_trace(optchat_chief::trace::Trace::open(&traces, false).unwrap());
    running(&mut h, "start the work");
    let sp = spawner(&h);
    run(&mut h, move || sp.send(send("On it."))).expect("send answers");
    let sp = spawner(&h);
    run(&mut h, move || sp.stop_turn()).expect("stop answers");
    h.agents.hold(false);
    h.settle_posts();
    let ends: Vec<serde_json::Value> = std::fs::read_dir(&traces)
        .unwrap()
        .flatten()
        .flat_map(|e| {
            std::fs::read_to_string(e.path())
                .unwrap()
                .lines()
                .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
                .collect::<Vec<_>>()
        })
        .filter(|e| e["ev"] == "turn.end")
        .collect();
    assert_eq!(ends.len(), 1, "{ends:?}");
    assert_eq!(ends[0]["status"], "stopped", "{}", ends[0]);
    assert!(
        ends[0]["error"].is_null(),
        "a stop is no error: {}",
        ends[0]
    );
}

#[test]
fn turn_tools_stop_outside_a_turn_is_a_noop() {
    let mut h = Harness::new(default_script());
    h.connect();
    let sp = spawner(&h);
    let answer = run(&mut h, move || sp.stop_turn()).expect("stop answers");
    assert!(answer.starts_with("outcome: noop"), "{answer}");
}

#[test]
fn turn_tools_sleep_ends_the_turn_and_wakes_the_chief_with_its_note() {
    let mut h = Harness::new(endless_first_turn());
    running(&mut h, "watch the nightly");
    let sp = spawner(&h);
    run(&mut h, move || sp.send(send("Watching it."))).expect("send answers");
    let sp = spawner(&h);
    let answer = run(&mut h, move || {
        sp.sleep(SleepCall {
            seconds: 600,
            note: Some("check nightly run 123".into()),
            until: None,
        })
    })
    .expect("sleep answers");
    assert!(answer.starts_with("outcome: done"), "{answer}");
    h.agents.hold(false);
    h.settle_posts();
    assert!(
        !h.agents.inner.lock().unwrap().cancels.is_empty(),
        "the session was cancelled"
    );
    let wakes = h.brain.pending_wakes();
    assert_eq!(wakes.len(), 1, "{wakes:?}");
    assert_eq!(wakes[0].note, "check nightly run 123");
    let prompts = h.agents.inner.lock().unwrap().prompts.len();
    // Not due yet: nothing happens.
    h.brain.fire_wakes_at(wakes[0].at_ms - 1);
    assert_eq!(h.brain.pending_wakes().len(), 1);
    // Due: a turn starts with the note.
    h.brain.fire_wakes_at(wakes[0].at_ms);
    h.settle_posts();
    assert!(h.brain.pending_wakes().is_empty());
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.prompts.len(), prompts + 1, "the wake ran a turn");
    let last = serde_json::to_string(inner.prompts.last().unwrap()).unwrap();
    assert!(
        last.contains("[wake]") && last.contains("check nightly run 123"),
        "{last}"
    );
}

#[test]
fn turn_tools_sleep_until_event_is_dropped_when_a_message_comes_first() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "wait for a12");
    h.settle_posts();
    let sp = spawner(&h);
    run(&mut h, move || {
        sp.sleep(SleepCall {
            seconds: 1800,
            note: Some("a12 should have reported".into()),
            until: Some("event".into()),
        })
    })
    .expect("sleep answers");
    assert_eq!(h.brain.pending_wakes().len(), 1);
    h.say("user_local", "a12 says it is done");
    h.settle_posts();
    assert!(
        h.brain.pending_wakes().is_empty(),
        "a turn for a message replaced the wake"
    );
}

#[test]
fn turn_tools_sleep_zero_clears_wakes_and_bounds_hold() {
    assert!(
        Call::parse("sleep", &json!({"seconds": 5})).is_err(),
        "under 30 s"
    );
    assert!(
        Call::parse("sleep", &json!({"seconds": 100000})).is_err(),
        "over 24 h"
    );
    assert!(
        Call::parse("sleep", &json!({"seconds": 0})).is_ok(),
        "0 clears"
    );
    assert!(
        Call::parse("sleep", &json!({"seconds": 60, "until": "never"})).is_err(),
        "until is time or event"
    );
    assert!(
        Call::parse("send", &json!({})).is_err(),
        "text or attachments"
    );
    let mut h = Harness::new(default_script());
    h.connect();
    let sp = spawner(&h);
    run(&mut h, move || {
        sp.sleep(SleepCall {
            seconds: 60,
            note: None,
            until: None,
        })
    })
    .unwrap();
    assert_eq!(h.brain.pending_wakes().len(), 1);
    let sp = spawner(&h);
    let cleared = run(&mut h, move || {
        sp.sleep(SleepCall {
            seconds: 0,
            note: None,
            until: None,
        })
    })
    .unwrap();
    assert!(cleared.contains("cleared"), "{cleared}");
    assert!(h.brain.pending_wakes().is_empty());
}

#[test]
fn turn_tools_the_chief_has_send_stop_and_sleep_and_a_subagent_does_not() {
    let names = |v: serde_json::Value| -> Vec<String> {
        v.as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_owned())
            .collect()
    };
    let chief = names(optchat_chief::mcp::tool_list());
    for tool in ["send", "stop", "sleep"] {
        assert!(chief.contains(&tool.to_owned()), "{chief:?}");
    }
    let sub = names(optchat_chief::mcp::tools_for(true));
    for tool in ["send", "stop", "sleep"] {
        assert!(!sub.contains(&tool.to_owned()), "{sub:?}");
    }
}
