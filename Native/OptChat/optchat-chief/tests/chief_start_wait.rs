//! A turn whose session is slow to start on a loaded machine: it waits on no wall clock of its
//! own, says how long it has taken, and a stop or the turn's limit still ends it.

mod common;

use std::sync::Mutex;
use std::time::Duration;

use common::FakeAgents;
use optchat_chief::acpmux::SessionSpec;
use optchat_chief::turn::{self, Interrupt, TurnOutcome, TurnStart};

fn held_turn(
    limit: Option<Duration>,
    on_notice: &dyn Fn(&Interrupt),
) -> (TurnOutcome, Vec<Option<u64>>, Vec<String>) {
    let dir = tempfile::tempdir().unwrap();
    let chat = common::open_chat(&dir.path().join("chat"));
    let agents = FakeAgents::new(Box::new(|_, _| Vec::new()));
    agents.inner.lock().unwrap().hold_starts = true;
    let start = TurnStart {
        key: "turn:optchat:0".into(),
        prompt_id: "optchat:0".into(),
        session: SessionSpec {
            name: "optchat-0".into(),
            cwd: dir.path().join("session"),
            harness: "claude-sr".into(),
            policy: "approve-all".into(),
            ..SessionSpec::default()
        },
        limit,
        ..Default::default()
    };
    let interrupt = Interrupt::new();
    let notices = Mutex::new(Vec::new());
    let starting = |secs: Option<u64>| {
        notices.lock().unwrap().push(secs);
        if secs.is_some() {
            on_notice(&interrupt);
        }
    };
    let outcome = turn::run_with_drafts(
        &*agents,
        &chat,
        &start,
        &interrupt,
        &|_| {},
        &|_, _| {},
        &optchat_chief::trace::Trace::off(),
        &|_| {},
        &|_| {},
        &starting,
    );
    let finds = agents.inner.lock().unwrap().finds.clone();
    (outcome, notices.into_inner().unwrap(), finds)
}

#[test]
fn a_stop_ends_a_slow_start_it_said_it_was_waiting_on() {
    let (outcome, notices, finds) = held_turn(None, &|interrupt| {
        interrupt.request();
    });
    assert!(outcome.cancelled, "{outcome:?}");
    assert_eq!(outcome.error, None);
    // Nothing for the first 30 s, then the count, then the notice is gone.
    assert_eq!(notices, vec![Some(30), None]);
    // Before the start (a name left by a host that stopped) and after it (its own start).
    assert_eq!(finds, vec!["optchat-0".to_owned(), "optchat-0".to_owned()]);
}

#[test]
fn the_turns_limit_still_ends_a_slow_start() {
    let (outcome, notices, finds) = held_turn(Some(Duration::from_millis(50)), &|_| {});
    assert!(!outcome.cancelled, "{outcome:?}");
    assert_eq!(
        outcome.error.as_deref(),
        Some("the session did not start within the turn's limit")
    );
    assert_eq!(notices.last(), Some(&None));
    assert_eq!(finds.len(), 2);
}
