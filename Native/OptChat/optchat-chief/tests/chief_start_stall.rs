//! A Chief turn whose agent does not start (Leo, 2026-11-04: "we need chief to be MUCH more
//! reliable. this should never be happening"). Every turn on that Mac failed with acpmux's start
//! deadline, "(turn failed on claude-sr2: session/new: agent_start did not finish within 90s; its
//! agent process (pid 9104) is alive ...)", posted as the Chief's reply, three times, and the
//! messages went unanswered. The memory compactor posted the same stall as a fault to fix.
//!
//! A turn whose prompt never reached a harness ran nothing, so it runs again; its raw start error
//! is never a reply; and if no try starts, the reply ledger says so in plain words. A compactor
//! start that stalls is a wait, not a notice.

mod common;

use std::time::{Duration, Instant};

use common::*;

/// acpmux's start deadline error, as the Chief conversation showed it.
const STALL: &str = "session/new: agent_start did not finish within 90s; its agent process (pid 9104) is alive at normal CPU class (priority 20), ran 87 s, used 0.1 s of CPU, 0 of 12 threads running";

fn prompts(h: &Harness) -> usize {
    h.agents.inner.lock().unwrap().prompts.len()
}

/// What the owner took from the Chief: its texts, in order.
fn posted(h: &Harness) -> Vec<String> {
    h.owner
        .lock()
        .unwrap()
        .sends()
        .into_iter()
        .map(|(_, text)| text)
        .collect()
}

/// Steps inputs and fires due timers (a cut turn's resume) until the brain is idle with no timer
/// due before `within`.
fn settle_with_timers(h: &mut Harness, within: Duration) {
    let deadline = Instant::now() + within;
    loop {
        assert!(Instant::now() < deadline, "the brain did not settle");
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        match h.brain.next_timer() {
            Some(at) if at < deadline => {
                std::thread::sleep(at.saturating_duration_since(Instant::now()));
                h.brain.on_timer();
            }
            _ if h.brain.is_idle() => return,
            _ => {}
        }
    }
}

fn harness() -> Harness {
    let mut h = Harness::new(default_script());
    h.brain
        .set_upstream_resume_backoff(vec![Duration::from_millis(1)]);
    h.brain.set_reply_retry_waits(vec![Duration::ZERO]);
    h
}

/// Nothing the Chief posted is a start's diagnostics.
fn assert_no_raw_error(h: &Harness) {
    for text in posted(h) {
        for raw in ["turn failed", "agent_start", "session/new", "pid 9104"] {
            assert!(!text.contains(raw), "posted {raw:?}: {text}");
        }
    }
}

#[test]
fn a_turn_whose_agent_did_not_start_runs_again_and_answers() {
    let mut h = harness();
    h.agents
        .inner
        .lock()
        .unwrap()
        .session_errors_once
        .push_back(STALL.into());
    h.connect();
    h.say("user_local", "surface the PRs that are ready for my review");
    settle_with_timers(&mut h, WAIT);
    assert_no_raw_error(&h);
    assert_eq!(prompts(&h), 1, "the turn that started ran once");
    let sent = posted(&h);
    assert!(sent.iter().any(|t| t.contains("answer 0")), "{sent:?}");
    assert!(
        h.brain.awaiting_replies().is_empty(),
        "the message is answered"
    );
}

#[test]
fn an_agent_that_never_starts_posts_no_diagnostics_and_the_message_stays_open() {
    let mut h = harness();
    h.agents
        .inner
        .lock()
        .unwrap()
        .session_errors
        .insert("claude-sr".into(), STALL.into());
    h.connect();
    h.say("user_local", "continue with this");
    settle_with_timers(&mut h, WAIT);
    assert_no_raw_error(&h);
    assert_eq!(prompts(&h), 0, "no harness ever took a prompt");
    // Nothing answered it: it waits for a retry turn, not closed by a failure post.
    let awaiting = h.brain.awaiting_replies();
    assert_eq!(awaiting.len(), 1, "{awaiting:?}");
    // The agent comes back: the retry turn answers the message.
    h.agents.inner.lock().unwrap().session_errors.clear();
    h.brain.fire_reply_checks_at(u64::MAX / 2);
    settle_with_timers(&mut h, WAIT);
    assert_no_raw_error(&h);
    assert_eq!(prompts(&h), 1);
    assert!(h.brain.awaiting_replies().is_empty());
    let sent = posted(&h);
    assert!(sent.iter().any(|t| t.contains("answer 0")), "{sent:?}");
}

#[test]
fn when_no_try_starts_the_person_hears_it_in_plain_words() {
    let mut h = harness();
    h.agents
        .inner
        .lock()
        .unwrap()
        .session_errors
        .insert("claude-sr".into(), STALL.into());
    h.connect();
    h.say("user_local", "continue with this");
    settle_with_timers(&mut h, WAIT);
    for _ in 0..=optchat_chief::brain::MAX_REPLY_TRIES {
        h.brain.fire_reply_checks_at(u64::MAX / 2);
        settle_with_timers(&mut h, WAIT);
    }
    assert_no_raw_error(&h);
    let sent = posted(&h);
    let note = sent
        .iter()
        .find(|t| t.contains("I could not answer your message"))
        .unwrap_or_else(|| panic!("no failure note: {sent:?}"));
    assert!(note.contains("its agent could not start"), "{note}");
    assert!(h.brain.awaiting_replies().is_empty());
}

/// The compactor's start-up probe (screenshot: "The memory compactor cannot build summaries
/// (acpmux route: ... agent_start did not finish within 90s ...). ... Check that acpmux runs and
/// that its Claude harness signs in").
#[test]
fn a_compactor_start_that_stalls_is_a_wait_and_no_notice() {
    let error = format!("the compactor model: starting a compactor session: {STALL}");
    assert_eq!(
        optchat_chief::host::probe_notice(optchat_chief::compactor::CompactRoute::Acpmux, &error),
        None
    );
    struct Now;
    impl optchat_chief::host::Delay for Now {
        fn wait(&self, _: Duration) -> bool {
            true
        }
    }
    let tries = std::sync::atomic::AtomicU32::new(0);
    let probe = || match tries.fetch_add(1, std::sync::atomic::Ordering::SeqCst) {
        0 => Err(error.clone()),
        _ => Ok("built".to_owned()),
    };
    let result = optchat_chief::host::probe_until_ready(&probe, &Now, &|_| {});
    assert_eq!(result, Some(Ok("built".to_owned())));
}

#[test]
fn a_memory_line_held_only_by_a_compactor_start_stall_posts_no_notice() {
    let node = optchat_core::NodeId::new(0, 3);
    let status = optchat_host::Status {
        messages: 0,
        view_lines: 0,
        view_size: 0,
        budget: 0,
        unbuilt: 0,
        built: 0,
        busy: Vec::new(),
        failures: vec![optchat_host::Failure {
            node,
            error: format!("starting a compactor session: {STALL}"),
        }],
        stuck: vec![node],
        recovered: false,
        fatal: None,
        closed: false,
    };
    assert_eq!(optchat_chief::brain::stuck_notice(&status), None);
}

/// A start refused for a reason the person must fix is not a stall: it still shows at once.
#[test]
fn a_start_refused_for_a_reason_still_shows() {
    let mut h = harness();
    h.agents.inner.lock().unwrap().session_errors.insert(
        "claude-sr".into(),
        "session/new: the acpmux preset optchat-chief is not installed".into(),
    );
    h.connect();
    h.say("user_local", "hi");
    settle_with_timers(&mut h, WAIT);
    let sent = posted(&h);
    assert!(
        sent.iter()
            .any(|t| t.contains("preset optchat-chief is not installed")),
        "{sent:?}"
    );
}

/// A harness that closed because it is not signed in is a fault the person must fix, not a stall.
#[test]
fn a_harness_that_is_not_signed_in_still_shows() {
    let mut h = harness();
    h.agents.inner.lock().unwrap().session_errors.insert(
        "claude-sr".into(),
        "session/new: agent process closed (claude): Not logged in · Please run /login".into(),
    );
    h.connect();
    h.say("user_local", "hi");
    settle_with_timers(&mut h, WAIT);
    let sent = posted(&h);
    assert!(sent.iter().any(|t| t.contains("Not logged in")), "{sent:?}");
}

/// acpmux's error for a start whose harness did no work for its whole wait (`start_hung`).
const HUNG: &str = "session/new: agent_start: its agent did no work for 300 s; its agent process (pid 15023, sr2, 5 processes in all) is alive at normal CPU class (priority 20), ran 502 s, used 0.5 s of CPU, 0 of 36 threads running, 0 page-ins; the first process it started is claude (pid 15041), which used 0.4 s of CPU and 0 page-ins";

/// #36028: a Chief start waits on its harness (`waitStart`), so a start that stays stuck ends as
/// acpmux's hung error, never its deadline. Its prompt reached no harness and acpmux ended that
/// harness, so a fresh one is tried: the message waits in the reply ledger and a retry turn
/// answers it, with no diagnostics posted and no in-turn cut waits (each hung try took 5 min).
#[test]
fn a_start_acpmux_ended_as_hung_runs_again_and_answers() {
    let mut h = harness();
    h.agents
        .inner
        .lock()
        .unwrap()
        .session_errors_once
        .push_back(HUNG.into());
    // Upstream cuts wait 15 s each: a hung start must not take them.
    h.brain
        .set_upstream_resume_backoff(vec![Duration::from_secs(15)]);
    h.connect();
    h.say("user_local", "surface the PRs that are ready for my review");
    let began = Instant::now();
    settle_with_timers(&mut h, WAIT);
    // The retry turn is the ledger's (its due check), not a cut's.
    h.brain.fire_reply_checks_at(u64::MAX / 2);
    settle_with_timers(&mut h, WAIT);
    assert!(
        began.elapsed() < Duration::from_secs(5),
        "{:?}",
        began.elapsed()
    );
    assert_no_raw_error(&h);
    for text in posted(&h) {
        assert!(!text.contains("did no work"), "{text}");
    }
    assert_eq!(prompts(&h), 1, "the fresh start took the prompt");
    let sent = posted(&h);
    assert!(sent.iter().any(|t| t.contains("answer 0")), "{sent:?}");
    assert!(
        h.brain.awaiting_replies().is_empty(),
        "the message is answered"
    );
}

/// A harness that hangs on every try (one waiting on a sign-in prompt) still ends: the ledger's
/// tries are the only ones, then the person hears in plain words that no agent started.
#[test]
fn a_harness_that_hangs_on_every_try_is_said_in_plain_words() {
    let mut h = harness();
    h.agents
        .inner
        .lock()
        .unwrap()
        .session_errors
        .insert("claude-sr".into(), HUNG.into());
    h.brain
        .set_upstream_resume_backoff(vec![Duration::from_secs(15)]);
    h.connect();
    h.say("user_local", "continue with this");
    let began = Instant::now();
    settle_with_timers(&mut h, WAIT);
    for _ in 0..=optchat_chief::brain::MAX_REPLY_TRIES {
        h.brain.fire_reply_checks_at(u64::MAX / 2);
        settle_with_timers(&mut h, WAIT);
    }
    assert!(
        began.elapsed() < Duration::from_secs(5),
        "{:?}",
        began.elapsed()
    );
    assert_no_raw_error(&h);
    let sent = posted(&h);
    for text in &sent {
        assert!(!text.contains("did no work"), "{text}");
    }
    let note = sent
        .iter()
        .find(|t| t.contains("I could not answer your message"))
        .unwrap_or_else(|| panic!("no failure note: {sent:?}"));
    assert!(note.contains("its agent could not start"), "{note}");
    assert!(h.brain.awaiting_replies().is_empty());
}

/// A turn an upstream 502 cut after its prompt reached a harness, whose resume then hangs: the cut
/// try may have done work, so it is not rerun as unstarted, but the person still never sees the
/// start's diagnostics, and no failure note closes the message: the next turn still sees it.
#[test]
fn a_hung_resume_after_a_cut_that_ran_says_it_in_plain_words() {
    // Turn 0 reaches its harness and is cut before its end (the 502 below).
    let full = default_script();
    let mut h = Harness::new(Box::new(move |turn, blocks| {
        if turn == 0 {
            vec![
                serde_json::json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "agent_message_chunk",
                    serde_json::json!({"content": {"type": "text", "text": "Checking."}}),
                ),
            ]
        } else {
            full(turn, blocks)
        }
    }));
    h.brain
        .set_upstream_resume_backoff(vec![Duration::from_millis(1)]);
    h.brain.set_reply_retry_waits(vec![Duration::ZERO]);
    h.agents.inner.lock().unwrap().answer_error =
        Some("API Error: 502 upstream request failed. This is a server-side issue".into());
    h.connect();
    h.say("user_local", "check the build");
    while prompts(&h) == 0 {
        h.step();
    }
    h.agents
        .inner
        .lock()
        .unwrap()
        .session_errors
        .insert("claude-sr".into(), HUNG.into());
    settle_with_timers(&mut h, WAIT);
    assert_eq!(prompts(&h), 1, "the resume's start hung before its prompt");
    assert_no_raw_error(&h);
    let sent = posted(&h);
    for text in &sent {
        assert!(!text.contains("did no work"), "{text}");
    }
    assert!(
        sent.iter().any(|t| t.contains("could not start an agent")),
        "{sent:?}"
    );
}

/// What the Chief posted in side conversation `conversation`.
fn side_posts(h: &Harness, conversation: &str) -> Vec<String> {
    let owner = h.owner.lock().unwrap();
    owner.stores[conversation]
        .ops
        .iter()
        .filter_map(|(_, op)| match op {
            cmux_conversation::Op::MessageSend { parts, .. } => match parts.first() {
                Some(cmux_conversation::Part::Text { text, .. }) => Some(text.clone()),
                _ => None,
            },
            _ => None,
        })
        .collect()
}

/// A member's message in a side conversation is not in the reply ledger: no retry turn follows, so
/// the stalled turn says in plain words that it could not start, never silence and never the
/// start's diagnostics.
#[test]
fn a_side_conversation_message_hears_in_plain_words_that_no_agent_started() {
    let mut h = harness();
    h.agents
        .inner
        .lock()
        .unwrap()
        .session_errors
        .insert("claude-sr".into(), STALL.into());
    h.connect();
    h.add_side("conv_side", "user_side");
    let question = h.post_side("conv_side", "user_side", "check the deploy");
    h.wake(&[("conv_side", question.seq)]);
    settle_with_timers(&mut h, WAIT);
    let sent = side_posts(&h, "conv_side");
    assert!(
        sent.iter().any(|t| t.contains("could not start an agent")),
        "{sent:?}"
    );
    for text in &sent {
        assert!(!text.contains("agent_start"), "{text}");
        assert!(!text.contains("turn failed"), "{text}");
    }
}
