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

/// A start acpmux ended because its harness did no work at all is a fault, not a slow machine.
#[test]
fn a_harness_acpmux_saw_stop_working_still_shows() {
    let mut h = harness();
    h.agents.inner.lock().unwrap().session_errors.insert(
        "claude-sr".into(),
        "session/new: agent_start: its agent did no work for 300 s; its agent process (pid 7) is alive".into(),
    );
    h.connect();
    h.say("user_local", "hi");
    settle_with_timers(&mut h, WAIT);
    let sent = posted(&h);
    assert!(sent.iter().any(|t| t.contains("did no work")), "{sent:?}");
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

/// A hung harness's error carries numbers (its pid, seconds) that must not read as an HTTP status
/// a retry cures: it shows on the first try.
#[test]
fn a_hung_harness_with_a_status_like_pid_shows_without_retries() {
    let mut h = harness();
    h.agents.inner.lock().unwrap().session_errors.insert(
        "claude-sr".into(),
        "session/new: agent_start: its agent did no work for 300 s; its agent process (pid 15023, 2 processes in all) is alive at normal CPU class (priority 20), ran 502 s, used 0.1 s of CPU, 0 of 12 threads running, 9 page-ins".into(),
    );
    // Upstream cuts wait 15 s each by default: a misread "502" would show only after them.
    h.brain
        .set_upstream_resume_backoff(vec![Duration::from_secs(15)]);
    h.connect();
    h.say("user_local", "hi");
    let began = Instant::now();
    settle_with_timers(&mut h, WAIT);
    let sent = posted(&h);
    assert_eq!(
        sent.iter().filter(|t| t.contains("did no work")).count(),
        1,
        "{sent:?}"
    );
    // Neither the in-turn session retries (6.5 s of backoff) nor an upstream cut ran.
    assert!(
        began.elapsed() < Duration::from_secs(5),
        "{:?}",
        began.elapsed()
    );
}
