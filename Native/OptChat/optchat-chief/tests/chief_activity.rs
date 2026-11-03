//! The Chief's Running list (brain/activity.rs, Leo 2026-11-02: "how about being able to see
//! background tasks and subagents within the chief ui?"): the inspector's `/api/activity`
//! answers the Chief's subagents, its watches with their last output, and its wakes, from the
//! brain, through the tools socket's `inspect` tool.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::inspect::{ACTIVITY_PATH, INSPECT_PATHS, activity_answer, asks_activity};
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::{ControlCall, Orchestrator, WatchCall};
use serde_json::{Value, json};

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

fn run<T: Send + 'static>(h: &mut Harness, f: impl FnOnce() -> T + Send + 'static) -> T {
    let worker = std::thread::spawn(f);
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(80)) {
        h.brain.step(input);
    }
    worker.join().unwrap()
}

fn activity(h: &mut Harness, sp: &Arc<Spawner>) -> Value {
    let a = sp.clone();
    let answer = run(h, move || {
        activity_answer(Some(move || {
            a.control(ControlCall {
                action: "activity".into(),
                ..ControlCall::default()
            })
        }))
    });
    assert_eq!(answer["status"], 200, "{answer}");
    answer["body"].clone()
}

#[test]
fn activity_lists_the_chiefs_subagents_watches_and_wakes() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    let sp = spawner(&h);
    h.brain.set_sub_starter(Some(sp.queue_starter()));

    let empty = activity(&mut h, &sp);
    assert_eq!(empty["subagents"], json!([]));
    assert_eq!(empty["watches"], json!([]));
    assert_eq!(empty["wakes"], json!([]));

    let a = sp.clone();
    run(&mut h, move || a.spawn(vec!["Fix the login page".into()], None)).unwrap();
    let a = sp.clone();
    run(&mut h, move || {
        a.watch(WatchCall {
            command: Some("sleep 600".into()),
            until: Some("MERGED".into()),
            note: Some("tell a1 it merged".into()),
            timeout_seconds: Some(3600),
            ..WatchCall::default()
        })
    })
    .unwrap();

    let now = activity(&mut h, &sp);
    let subs = now["subagents"].as_array().unwrap();
    assert_eq!(subs.len(), 1, "{now}");
    assert_eq!(subs[0]["id"], "a1");
    assert!(subs[0]["title"].as_str().unwrap().contains("login"), "{now}");
    assert_eq!(subs[0]["at_work"], true);
    assert!(subs[0]["started_ms"].as_u64().is_some(), "{now}");
    assert!(subs[0]["state"].as_str().is_some_and(|s| !s.is_empty()), "{now}");
    let watches = now["watches"].as_array().unwrap();
    assert_eq!(watches.len(), 1, "{now}");
    assert_eq!(watches[0]["id"], "w1");
    assert_eq!(watches[0]["command"], "sleep 600");
    assert_eq!(watches[0]["until"], "MERGED");
    assert_eq!(watches[0]["note"], "tell a1 it merged");
    assert!(watches[0]["latest"].is_array(), "{now}");
    let a = sp.clone();
    run(&mut h, move || {
        a.watch(WatchCall {
            cancel: Some("all".into()),
            ..WatchCall::default()
        })
    })
    .unwrap();
}

#[test]
fn the_activity_path_is_an_inspector_read_the_brain_answers() {
    assert!(INSPECT_PATHS.contains(&ACTIVITY_PATH));
    assert!(asks_activity(&json!({"tool": "inspect", "path": "/api/activity"})));
    assert!(!asks_activity(&json!({"tool": "inspect", "method": "POST", "path": "/api/activity"})));
    assert!(!asks_activity(&json!({"tool": "inspect", "path": "/api/status"})));
    let none: Option<fn() -> Result<String, String>> = None;
    assert_eq!(activity_answer(none)["status"], 503);
    assert_eq!(activity_answer(Some(|| Err::<String, String>("stopping".into())))["status"], 503);
    assert_eq!(activity_answer(Some(|| Ok::<String, String>("{\"subagents\":[]}".into())))["body"]["subagents"], json!([]));
}
