//! Every person message of the Chief conversation gets a reply (user
//! 2026-10-21: "we need better durability so the Chief never forgets to
//! respond"). A turn that ends with NO_REPLY, ends silent, or whose reply the
//! owner refuses leaves the message in the reply ledger; a retry turn
//! answers it, and after the retries the person gets a failure note. The
//! ledger survives a host restart.

mod common;

use common::{Harness, Script, default_script, update};
use optchat_chief::brain::{MAX_REPLY_TRIES, NO_REPLY_TAG};
use serde_json::json;

/// Turn `i` ends with `texts[i]` (the last one repeats); "" says nothing.
fn says(texts: Vec<&'static str>) -> Script {
    Box::new(move |turn, _| {
        let text = texts.get(turn).or(texts.last()).copied().unwrap_or("");
        let mut events = vec![json!({"dir": "mux", "kind": "turn_started", "msg": {}})];
        if !text.is_empty() {
            events.push(update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": text}}),
            ));
        }
        events.push(json!({"dir": "mux", "kind": "turn_end", "msg": {}}));
        events
    })
}

/// What the owner took from the Chief: its texts, in order.
fn posted(h: &Harness) -> Vec<String> {
    h.owner
        .lock()
        .unwrap()
        .messages
        .iter()
        .filter(|m| m.author != "user_local")
        .filter_map(|m| match m.parts.first() {
            Some(cmux_conversation::Part::Text { text, .. }) => Some(text.clone()),
            _ => None,
        })
        .collect()
}

fn prompts(h: &Harness) -> Vec<String> {
    h.agents
        .inner
        .lock()
        .unwrap()
        .prompts
        .iter()
        .map(|blocks| serde_json::to_string(blocks).unwrap())
        .collect()
}

/// Every due reply check runs now, then the brain settles.
fn fire(h: &mut Harness) {
    h.brain.fire_reply_checks_at(u64::MAX / 2);
    h.settle_posts();
}

#[test]
fn no_reply_to_a_person_message_is_refused_and_a_retry_turn_answers() {
    let mut h = Harness::new(says(vec!["NO_REPLY", "Deployed to staging."]));
    h.connect();
    h.say("user_local", "deploy it");
    h.settle_posts();
    assert!(posted(&h).is_empty(), "NO_REPLY posts nothing itself");
    let awaiting = h.brain.awaiting_replies();
    assert_eq!(awaiting.len(), 1, "{awaiting:?}");
    assert_eq!(awaiting[0].id, "msg_1");
    assert!(awaiting[0].due_ms.is_some(), "a retry check is due");
    fire(&mut h);
    assert_eq!(posted(&h), vec!["Deployed to staging.".to_owned()]);
    assert!(h.brain.awaiting_replies().is_empty());
    let p = prompts(&h);
    assert_eq!(p.len(), 2, "one retry turn");
    assert!(p[1].contains(NO_REPLY_TAG), "{}", p[1]);
    assert!(p[1].contains("deploy it"), "{}", p[1]);
    assert!(p[1].contains("NO_REPLY"), "{}", p[1]);
}

#[test]
fn a_turn_that_ends_silent_gets_a_retry() {
    let mut h = Harness::new(says(vec!["", "Here it is."]));
    h.connect();
    h.say("user_local", "send me the link");
    h.settle_posts();
    assert!(posted(&h).is_empty());
    assert_eq!(h.brain.awaiting_replies().len(), 1);
    fire(&mut h);
    assert_eq!(posted(&h), vec!["Here it is.".to_owned()]);
    assert!(h.brain.awaiting_replies().is_empty());
}

#[test]
fn after_the_retries_the_person_gets_a_failure_note() {
    let mut h = Harness::new(says(vec!["NO_REPLY"]));
    h.connect();
    h.say("user_local", "deploy it");
    h.settle_posts();
    for _ in 0..=MAX_REPLY_TRIES {
        fire(&mut h);
    }
    let posts = posted(&h);
    assert_eq!(posts.len(), 1, "{posts:?}");
    assert!(
        posts[0].starts_with("I could not answer your message \"deploy it\""),
        "{posts:?}"
    );
    assert!(h.brain.awaiting_replies().is_empty());
    assert_eq!(prompts(&h).len(), 1 + MAX_REPLY_TRIES as usize);
    // Nothing more: the note closes the message.
    fire(&mut h);
    assert_eq!(posted(&h).len(), 1);
    assert_eq!(prompts(&h).len(), 1 + MAX_REPLY_TRIES as usize);
    // The failure note goes into the message's thread.
    let owner = h.owner.lock().unwrap();
    let reply_to = owner.ops.iter().find_map(|(_, op)| match op {
        cmux_conversation::Op::MessageSend { reply_to, .. } => Some(reply_to.clone()),
        _ => None,
    });
    assert_eq!(
        reply_to.flatten().map(|r| r.message_id),
        Some("msg_1".to_owned())
    );
}

#[test]
fn a_refused_reply_post_is_retried() {
    let mut h = Harness::new(says(vec!["First try.", "Second try."]));
    h.owner
        .lock()
        .unwrap()
        .rejects
        .push_back(Some("payload_invalid".into()));
    h.connect();
    h.say("user_local", "status?");
    h.settle_posts();
    assert!(posted(&h).is_empty(), "the owner refused the reply");
    assert_eq!(h.brain.awaiting_replies().len(), 1);
    fire(&mut h);
    assert_eq!(posted(&h), vec!["Second try.".to_owned()]);
    assert!(h.brain.awaiting_replies().is_empty());
}

#[test]
fn the_ledger_survives_a_host_restart() {
    let mut h = Harness::new(says(vec!["NO_REPLY"]));
    h.connect();
    h.say("user_local", "deploy it");
    h.settle_posts();
    assert_eq!(h.brain.awaiting_replies().len(), 1);
    let Harness {
        dir,
        owner,
        chat,
        brain,
        ..
    } = h;
    drop(brain);
    chat.shutdown();
    drop(chat);
    let mut h = Harness::in_dir(dir, says(vec!["On it: deployed."]), owner);
    h.connect();
    h.settle_posts();
    let awaiting = h.brain.awaiting_replies();
    assert_eq!(awaiting.len(), 1, "the restart kept it: {awaiting:?}");
    fire(&mut h);
    assert_eq!(posted(&h), vec!["On it: deployed.".to_owned()]);
    assert!(h.brain.awaiting_replies().is_empty());
}

#[test]
fn an_answered_message_needs_no_retry() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.say("user_local", "hi");
    h.settle_posts();
    assert!(h.brain.awaiting_replies().is_empty());
    fire(&mut h);
    assert_eq!(prompts(&h).len(), 1, "no retry turn");
}

#[test]
fn a_retracted_message_needs_no_reply() {
    let mut h = Harness::new(says(vec!["NO_REPLY"]));
    h.connect();
    let mut m = h.say("user_local", "never mind this");
    h.settle_posts();
    assert_eq!(h.brain.awaiting_replies().len(), 1);
    m.retracted_at = Some("2026-10-21T00:00:00.000Z".into());
    h.brain.step(optchat_chief::brain::Input::from(
        optchat_chief::daemon::DaemonEvent::Changed {
            conversation: common::CONV.into(),
            change: cmux_conversation::Change::MessageUpdated { message: m },
        },
    ));
    assert!(h.brain.awaiting_replies().is_empty());
}

#[test]
fn a_host_notice_is_no_reply() {
    let mut h = Harness::new(says(vec!["NO_REPLY"]));
    h.connect();
    h.say("user_local", "deploy it");
    h.settle_posts();
    assert_eq!(h.brain.awaiting_replies().len(), 1);
    // The host's own message (a notice) answers nothing.
    h.brain
        .notice_for_test("notice:test", "The Chief's memory cannot summarize line 3.");
    h.settle_posts();
    assert_eq!(posted(&h).len(), 1, "the notice posted");
    assert_eq!(
        h.brain.awaiting_replies().len(),
        1,
        "still waiting for a reply"
    );
}
