//! A user's tapback on a Chief message may wake the Chief (Lawrence
//! 2026-10-21, msg 9070: "it should sometimes cause a turn tho... maybe it
//! should go through a cheap model first to determine if it should start a
//! turn. we need to be careful to avoid that i do reaction on ur message,
//! you start typing indicator, then stop typing indicator since i reacted to
//! something trivial"; a416). A cheap classifier (Claude Haiku by default)
//! decides wake or no wake after a short debounce; nothing turn-visible (the
//! typing dots, a turn) shows before it says wake; each decision is a note
//! with its reason; a failure is no wake; `reactions_can_wake` turns it off.

mod common;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_conversation::{Change, Message, Reaction, ReactionKind, Tapback};
use common::*;
use optchat_chief::brain::{Input, JudgeAsk, ReactionJudge};
use optchat_chief::daemon::DaemonEvent;

/// The fake classifier's scripted answer.
type Answer = Box<dyn FnMut(&JudgeAsk) -> Result<String, String> + Send>;

/// A classifier that answers from a script and records what it was asked,
/// with how many typing events the owner had seen at that moment.
struct FakeJudge {
    answer: Mutex<Answer>,
    asks: Mutex<Vec<(JudgeAsk, usize)>>,
    owner: Arc<Mutex<Owner>>,
}

impl ReactionJudge for FakeJudge {
    fn judge(&self, ask: &JudgeAsk) -> Result<String, String> {
        let typed = self.owner.lock().unwrap().typing.len();
        self.asks.lock().unwrap().push((ask.clone(), typed));
        (self.answer.lock().unwrap())(ask)
    }
}

fn judge(
    h: &mut Harness,
    answer: impl FnMut(&JudgeAsk) -> Result<String, String> + Send + 'static,
) -> Arc<FakeJudge> {
    let judge = Arc::new(FakeJudge {
        answer: Mutex::new(Box::new(answer)),
        asks: Mutex::new(Vec::new()),
        owner: h.owner.clone(),
    });
    h.brain.set_reaction_judge(judge.clone());
    h.brain.set_reaction_debounce(Duration::from_millis(60));
    judge
}

/// The Chief's reply to a first "hi": (its message, its first line).
fn chief_reply(h: &mut Harness) -> Message {
    h.connect();
    h.say("user_local", "hi");
    h.settle_posts();
    h.owner
        .lock()
        .unwrap()
        .messages
        .iter()
        .find(|m| m.author == "agent_mux")
        .cloned()
        .expect("the Chief replied")
}

/// The owner's update of `message` with the user's reactions set to `kinds`.
fn react(h: &mut Harness, message: &Message, kinds: &[ReactionKind]) {
    let mut m = message.clone();
    m.reactions = kinds
        .iter()
        .map(|kind| Reaction {
            author: "user_local".into(),
            part_index: 0,
            kind: kind.clone(),
            at: "2026-10-21T20:00:00Z".into(),
        })
        .collect();
    {
        let mut owner = h.owner.lock().unwrap();
        if let Some(slot) = owner.messages.iter_mut().find(|x| x.seq == m.seq) {
            *slot = m.clone();
        }
    }
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::MessageUpdated { message: m },
    }));
}

/// Past the debounce, the classifier's answer in, and any turn it woke done.
fn decide(h: &mut Harness) {
    let until = Instant::now() + WAIT;
    while let Some(at) = h.brain.next_timer() {
        assert!(Instant::now() < until, "the reaction timer never settled");
        std::thread::sleep(at.saturating_duration_since(Instant::now()));
        h.brain.on_timer();
        h.settle();
    }
    h.settle_posts();
}

fn notes(h: &Harness, prefix: &str) -> Vec<String> {
    h.log()
        .into_iter()
        .filter(|(kind, text)| kind == "note" && text.starts_with(prefix))
        .map(|(_, text)| text)
        .collect()
}

fn prompts(h: &Harness) -> usize {
    h.agents.inner.lock().unwrap().prompts.len()
}

#[test]
fn reaction_wake_a_trivial_reaction_never_shows_the_typing_dots_or_starts_a_turn() {
    let mut h = Harness::new(default_script());
    let reply = chief_reply(&mut h);
    let judge = judge(&mut h, |_| Ok("SKIP: a thank-you on a status line".into()));
    let before = prompts(&h);
    h.owner.lock().unwrap().typing.clear();
    react(&mut h, &reply, &[ReactionKind::Tapback(Tapback::Love)]);
    decide(&mut h);
    assert_eq!(judge.asks.lock().unwrap().len(), 1, "one classifier call");
    assert!(
        h.owner.lock().unwrap().typing.is_empty(),
        "no typing event for a trivial reaction: {:?}",
        h.owner.lock().unwrap().typing
    );
    assert_eq!(prompts(&h), before, "no turn");
    let decided = notes(&h, "reaction ");
    assert_eq!(decided.len(), 1, "{decided:?}");
    assert!(
        decided[0].contains("❤️ love")
            && decided[0].contains("no wake: a thank-you on a status line"),
        "the decision and its reason: {decided:?}"
    );
}

#[test]
fn reaction_wake_a_question_on_a_question_wakes_the_chief_and_only_then_types() {
    let mut h = Harness::new(default_script());
    let reply = chief_reply(&mut h);
    let judge = judge(&mut h, |_| Ok("WAKE: a question mark on a proposal".into()));
    let before = prompts(&h);
    h.owner.lock().unwrap().typing.clear();
    react(&mut h, &reply, &[ReactionKind::Tapback(Tapback::Question)]);
    decide(&mut h);
    let asks = judge.asks.lock().unwrap().clone();
    assert_eq!(asks.len(), 1);
    assert_eq!(
        asks[0].1, 0,
        "no typing event before the classifier answered"
    );
    assert!(
        asks[0].0.prompt.contains("❓ question"),
        "{}",
        asks[0].0.prompt
    );
    assert!(prompts(&h) > before, "the reaction started a turn");
    assert_eq!(
        h.owner.lock().unwrap().typing.first(),
        Some(&true),
        "the turn shows the typing dots"
    );
    let turn: String = h
        .agents
        .inner
        .lock()
        .unwrap()
        .prompts
        .last()
        .unwrap()
        .iter()
        .map(|b| b["text"].as_str().unwrap_or_default())
        .collect();
    assert!(
        turn.contains("❓ question") && turn.contains("wake: a question mark on a proposal"),
        "the turn reads the reaction and why it woke: {turn}"
    );
}

#[test]
fn reaction_wake_quick_swaps_are_one_decision_on_the_last_reaction() {
    let mut h = Harness::new(default_script());
    let reply = chief_reply(&mut h);
    let judge = judge(&mut h, |_| Ok("SKIP: an acknowledgement".into()));
    react(&mut h, &reply, &[ReactionKind::Tapback(Tapback::Like)]);
    react(&mut h, &reply, &[ReactionKind::Tapback(Tapback::Love)]);
    react(&mut h, &reply, &[ReactionKind::Emoji("🔥".into())]);
    assert!(
        judge.asks.lock().unwrap().is_empty(),
        "nothing is judged inside the debounce"
    );
    decide(&mut h);
    let asks = judge.asks.lock().unwrap().clone();
    assert_eq!(asks.len(), 1, "one decision for the swaps: {asks:?}");
    assert!(asks[0].0.prompt.contains("🔥"), "{}", asks[0].0.prompt);
    assert!(
        !asks[0].0.prompt.contains("👍 like"),
        "{}",
        asks[0].0.prompt
    );
    assert_eq!(notes(&h, "reaction ").len(), 1);
    // The same update again (a reconnect's replay) is not judged twice.
    react(&mut h, &reply, &[ReactionKind::Emoji("🔥".into())]);
    decide(&mut h);
    assert_eq!(
        judge.asks.lock().unwrap().len(),
        1,
        "a replay is decided once"
    );
    // Swapped away and back within the debounce: nothing new to decide.
    react(&mut h, &reply, &[]);
    decide(&mut h);
    assert_eq!(
        judge.asks.lock().unwrap().len(),
        1,
        "a removal asks nothing"
    );
}

#[test]
fn reaction_wake_a_failed_or_silent_classifier_is_no_wake() {
    let mut h = Harness::new(default_script());
    let reply = chief_reply(&mut h);
    let mut n = 0;
    judge(&mut h, move |_| {
        n += 1;
        if n == 1 {
            Err("classifier timed out after 20 s".into())
        } else {
            Ok("maybe?".into())
        }
    });
    let before = prompts(&h);
    h.owner.lock().unwrap().typing.clear();
    react(&mut h, &reply, &[ReactionKind::Tapback(Tapback::Question)]);
    decide(&mut h);
    react(&mut h, &reply, &[ReactionKind::Tapback(Tapback::Dislike)]);
    decide(&mut h);
    assert_eq!(prompts(&h), before, "no turn");
    assert!(h.owner.lock().unwrap().typing.is_empty());
    let decided = notes(&h, "reaction ");
    assert_eq!(decided.len(), 2, "{decided:?}");
    assert!(
        decided[0].contains("no wake: the classifier failed (classifier timed out after 20 s)"),
        "{decided:?}"
    );
    assert!(
        decided[1].contains("no wake: the classifier gave no WAKE or SKIP"),
        "{decided:?}"
    );
}

#[test]
fn reaction_wake_reactions_can_wake_off_keeps_the_quiet_note_and_asks_no_classifier() {
    let mut h = Harness::new(default_script());
    let reply = chief_reply(&mut h);
    let judge = judge(&mut h, |_| Ok("WAKE: should not be asked".into()));
    h.brain.set_reaction_wake_override(Some(false));
    react(&mut h, &reply, &[ReactionKind::Tapback(Tapback::Question)]);
    decide(&mut h);
    assert!(judge.asks.lock().unwrap().is_empty());
    let decided = notes(&h, "reaction ");
    assert_eq!(decided.len(), 1, "{decided:?}");
    assert!(!decided[0].contains("wake"), "the plain note: {decided:?}");
}

#[test]
fn reaction_wake_the_classifier_runs_on_claude_haiku_by_default_and_on_what_is_configured() {
    use optchat_chief::brain::reaction_wake::{DEFAULT_MODEL, ReactionWakeConfig};
    use optchat_chief::engine::EngineChoice;
    use serde_json::json;
    let defaults = ReactionWakeConfig::resolve(&EngineChoice::default(), None);
    assert_eq!(DEFAULT_MODEL, "claude-haiku-5-5");
    assert_eq!(defaults.model, DEFAULT_MODEL);
    assert!(defaults.can_wake);
    assert!(defaults.harness.is_none(), "the host's Claude route");
    assert!(defaults.prompt.contains("WAKE") && defaults.prompt.contains("SKIP"));
    // The user's cmux.json, then this Chief's own engine.json over it.
    let user = json!({"chief": {"reactionsCanWake": false, "reactionClassifier": {
        "harness": "claude-sr2", "model": "claude-sonnet-5-5", "prompt": "Wake only on 👎."}}});
    let mine = ReactionWakeConfig::resolve(&EngineChoice::default(), Some(&user));
    assert!(!mine.can_wake);
    assert_eq!(mine.harness.as_deref(), Some("claude-sr2"));
    assert_eq!(mine.model, "claude-sonnet-5-5");
    assert_eq!(mine.prompt, "Wake only on 👎.");
    let chief = EngineChoice {
        classifier_model: Some("gpt-5.5-mini".into()),
        classifier_harness: Some("codex".into()),
        reactions_can_wake: Some(true),
        ..EngineChoice::default()
    };
    let own = ReactionWakeConfig::resolve(&chief, Some(&user));
    assert!(own.can_wake, "the Chief's own setting wins");
    assert_eq!(own.harness.as_deref(), Some("codex"));
    assert_eq!(own.model, "gpt-5.5-mini");
    assert_eq!(
        own.prompt, "Wake only on 👎.",
        "an unset field falls back to the user's"
    );

    // The classifier is asked with the configured model, harness and prompt.
    let mut h = Harness::new(default_script());
    let reply = chief_reply(&mut h);
    let judge = judge(&mut h, |_| Ok("SKIP: fine".into()));
    h.brain.set_reaction_user_settings(Some(user));
    h.brain.set_reaction_wake_override(Some(true));
    react(&mut h, &reply, &[ReactionKind::Tapback(Tapback::Dislike)]);
    decide(&mut h);
    let asks = judge.asks.lock().unwrap().clone();
    assert_eq!(asks.len(), 1);
    assert_eq!(asks[0].0.model, "claude-sonnet-5-5");
    assert_eq!(asks[0].0.harness.as_deref(), Some("claude-sr2"));
    assert!(
        asks[0].0.prompt.starts_with("Wake only on 👎."),
        "{}",
        asks[0].0.prompt
    );
}
