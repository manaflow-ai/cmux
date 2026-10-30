//! Chief fast eval, group assistant (#25576: "Chief should feel like a
//! strong personal assistant: remembers preferences, follows up on open work
//! unasked, ... keeps answers short and actionable"). Host behavior only, no
//! model call:
//!
//! - A preference `remember` kept after the host started reaches the next
//!   turn (its tail) and a new subagent (its task), although the system
//!   prompt was made before it; one the prompt holds already is not repeated.
//! - A reply that promises to come back, in a turn that set no wake and left
//!   no subagent at work, gets a wake from the host.
//! - A reply that ends by handing a decision back ("Want me to fix it?")
//!   gets one `[decide]` turn; a question about money, deletes or sign-ins
//!   does not, and the `[decide]` turn's own reply gets no second one.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use optchat_chief::brain::Settings;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use serde_json::{Value, json};

const OLD: &str = "Never force push. (learned 2026-10-20)";
const NEW: &str = "Default project is cmux-next; never ask which project. (learned 2026-10-26)";

/// A turn whose final reply is `text`.
fn reply(text: &str) -> Vec<Value> {
    vec![
        json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
        update(
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": text}}),
        ),
        json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
    ]
}

/// Turn n replies `texts[n]` (the last one after that).
fn replies(texts: &'static [&'static str]) -> Script {
    Box::new(move |turn, _| reply(texts[turn.min(texts.len() - 1)]))
}

fn text_of(blocks: &[Value]) -> String {
    serde_json::to_string(blocks).unwrap()
}

/// A harness whose profile held `OLD` when the host started (its system
/// text has it) and holds `NEW` too now.
fn with_profile(script: Script) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let person = dir.path().join("optchat/person.md");
    std::fs::create_dir_all(person.parent().unwrap()).unwrap();
    let start = format!("# The user\n\n## Learned\n\n- {OLD}\n");
    std::fs::write(&person, format!("{start}- {NEW}\n")).unwrap();
    let settings = Settings {
        system_text: optchat_chief::prompt::claude_md(Some(&start)),
        person: Some(person),
        ..settings(dir.path())
    };
    let owner = Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    Harness::configured(dir, script, owner, settings, Arc::new(|_: &str| {}))
}

#[test]
fn a_preference_learned_since_the_start_reaches_the_next_turn() {
    let mut h = with_profile(replies(&["Started a12 on it."]));
    h.connect();
    h.say("user_local", "the sidebar flickers, fix it");
    h.settle();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    let turn = text_of(&prompts[0]);
    assert!(
        turn.contains(NEW),
        "the new preference is in the turn: {turn}"
    );
    assert!(
        !turn.contains(OLD),
        "a preference the system prompt holds is not repeated: {turn}"
    );
}

#[test]
fn a_preference_learned_since_the_start_reaches_a_new_subagent() {
    let mut h = with_profile(default_script());
    let person = h.dir.path().join("optchat/person.md");
    // The host read the profile at start: only OLD then.
    let now = std::fs::read_to_string(&person).unwrap();
    std::fs::write(&person, format!("# The user\n\n## Learned\n\n- {OLD}\n")).unwrap();
    let sp = Arc::new(
        Spawner::new(
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
        )
        .with_person(person.clone()),
    );
    std::fs::write(&person, now).unwrap();
    let worker = std::thread::spawn(move || sp.spawn(vec!["Fix the flicker.".into()], None));
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    worker.join().unwrap().unwrap();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    let task = prompts
        .iter()
        .map(|p| text_of(p))
        .find(|t| t.contains("Fix the flicker."))
        .expect("the subagent's first prompt");
    assert!(
        task.contains(NEW),
        "the task names the new preference: {task}"
    );
    assert!(
        !task.contains(OLD),
        "not the one its system text has: {task}"
    );
}

#[test]
fn a_promise_with_no_wake_gets_one() {
    let mut h = Harness::new(replies(&[
        "The deploy is running. I'll check back when it is done.",
    ]));
    h.connect();
    h.say("user_local", "deploy the docs site");
    h.settle();
    let wakes = h.brain.pending_wakes();
    assert_eq!(wakes.len(), 1, "{wakes:?}");
    let wake = &wakes[0];
    assert!(wake.note.contains("I'll check back"), "{}", wake.note);
    assert_eq!(
        (wake.at_ms - wake.asked_ms) / 1000,
        optchat_chief::assistant::PROMISE_WAKE_SECS
    );
}

#[test]
fn a_reply_with_no_promise_sets_no_wake() {
    let mut h = Harness::new(replies(&["Deployed: docs site is live."]));
    h.connect();
    h.say("user_local", "deploy the docs site");
    h.settle();
    assert!(h.brain.pending_wakes().is_empty());
}

#[test]
fn a_reply_that_ends_with_an_offer_gets_one_decide_turn() {
    let mut h = Harness::new(replies(&[
        "Found it: the drag handler reloads the whole group.\n\nWant me to fix it?",
        "Default picked: fixing it. Started a12. Want me to also add a test?",
    ]));
    h.connect();
    h.say("user_local", "why does the sidebar flicker when I drag?");
    h.settle();
    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    assert_eq!(prompts.len(), 2, "one decide turn, no more");
    let decide = text_of(&prompts[1]);
    assert!(decide.contains("[decide]"), "{decide}");
    assert!(decide.contains("Want me to fix it?"), "{decide}");
}

#[test]
fn a_question_that_needs_the_person_stays_a_question() {
    let mut h = Harness::new(replies(&[
        "12 merged branches are left. Want me to delete them?",
    ]));
    h.connect();
    h.say("user_local", "clean up my branches");
    h.settle();
    assert_eq!(h.agents.inner.lock().unwrap().prompts.len(), 1);
}

#[test]
fn the_prompt_says_to_end_with_the_result() {
    let p = optchat_chief::prompt::claude_md(None);
    assert!(p.contains("End every reply with the result"), "{p}");
    assert!(p.contains("preferences the user gave since your prompt"));
}
