//! G9 durability: the wake queue's acks and the side floors. A wake is acked
//! (`cloud-mux-ack`) only once its conversation's floor is saved and no
//! reply for it waits: after the owner accepts the reply, or at once for a
//! message that does not wake. A wake repeated after a crash is dropped by
//! the saved floor and acked; a reply saved before a crash posts once. The
//! floors are bounded: a closed conversation's floor goes, and one without a
//! wake for `FLOOR_RETENTION_DAYS` is pruned.

mod common;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use cmux_conversation::{Participant, ParticipantKind};
use common::*;
use optchat_chief::state::{FLOOR_RETENTION_DAYS, HostState, SideFloor, StateFile};

const SIDE: &str = "conv_side";
const BOB: &str = "user_bob";
const DAY_MS: u64 = 86_400_000;

fn settle_all(h: &mut Harness) {
    h.settle();
    while let Some(at) = h.brain.next_timer() {
        std::thread::sleep(at.saturating_duration_since(Instant::now()));
        h.brain.on_timer();
    }
}

fn acks(h: &Harness) -> Vec<(String, u64)> {
    h.owner.lock().unwrap().acks.clone()
}

fn prompts(h: &Harness) -> usize {
    h.agents.inner.lock().unwrap().prompts.len()
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// Stops the brain as a crash would (no turn end, nothing flushed) and
/// starts a new one on the same home and owner.
fn restart(h: Harness) -> Harness {
    let Harness {
        dir,
        chat,
        owner,
        brain,
        ..
    } = h;
    drop(brain);
    chat.shutdown();
    drop(chat);
    Harness::in_dir(dir, default_script(), owner)
}

#[test]
fn a_side_wake_is_acked_only_after_the_owner_accepts_the_reply() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.add_side(SIDE, BOB);
    h.owner
        .lock()
        .unwrap()
        .stores
        .get_mut(SIDE)
        .unwrap()
        .rejects = VecDeque::from([Some("agent_rate".to_owned())]);
    h.post_side(SIDE, BOB, "hello chief");
    h.wake(&[(SIDE, 1)]);
    h.step();
    h.agents.wait_prompts(1);
    assert!(acks(&h).is_empty(), "the turn runs: no ack yet");
    h.agents.release();
    h.settle();
    assert_eq!(h.side_sends(SIDE).len(), 1, "the reply was tried once");
    assert!(
        acks(&h).is_empty(),
        "the owner refused the reply (agent_rate): it waits, so the wake is not acked"
    );
    settle_all(&mut h);
    assert_eq!(h.side_sends(SIDE).len(), 2, "the retry is accepted");
    assert_eq!(acks(&h), vec![(SIDE.to_owned(), 1)]);
    assert_eq!(h.brain.state().side[SIDE].seq, 1);
}

#[test]
fn a_side_message_that_does_not_wake_is_acked_after_its_floor_is_saved() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.add_side(SIDE, BOB);
    // A group of two people and the Chief: no mention, no wake.
    h.owner
        .lock()
        .unwrap()
        .stores
        .get_mut(SIDE)
        .unwrap()
        .summary
        .participants
        .push(Participant {
            id: "user_carol".into(),
            kind: ParticipantKind::Human,
            display_name: "Carol".into(),
            agent_class: None,
            acp_session: None,
            person: None,
        });
    h.post_side(SIDE, BOB, "lunch, carol?");
    h.wake(&[(SIDE, 1)]);
    settle_all(&mut h);
    assert_eq!(prompts(&h), 0, "no turn");
    assert_eq!(h.brain.state().side[SIDE].seq, 1, "the floor is saved");
    assert_eq!(acks(&h), vec![(SIDE.to_owned(), 1)]);
}

#[test]
fn a_main_wake_is_acked_once_its_message_is_answered() {
    let mut h = Harness::new(default_script());
    h.connect();
    // The queue's wake can come before the main stream's message.
    h.wake(&[(CONV, 1)]);
    assert!(acks(&h).is_empty(), "the message is not handled yet");
    h.say("user_local", "hello");
    settle_all(&mut h);
    assert_eq!(h.owner.lock().unwrap().sends().len(), 1);
    assert_eq!(acks(&h), vec![(CONV.to_owned(), 1)]);
}

#[test]
fn a_wake_repeated_after_a_crash_is_dropped_and_acked() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.add_side(SIDE, BOB);
    h.post_side(SIDE, BOB, "hello chief");
    h.wake(&[(SIDE, 1)]);
    settle_all(&mut h);
    assert_eq!(h.side_sends(SIDE).len(), 1);
    let logged = h.log().len();
    // The ack was lost with the crash: the queue delivers the wake again.
    h.owner.lock().unwrap().acks.clear();
    let mut h = restart(h);
    h.connect();
    h.wake(&[(SIDE, 1)]);
    settle_all(&mut h);
    assert_eq!(prompts(&h), 0, "the saved floor drops the repeat");
    assert_eq!(h.side_sends(SIDE).len(), 1, "no second reply");
    assert_eq!(h.log().len(), logged, "nothing is logged twice");
    assert_eq!(acks(&h), vec![(SIDE.to_owned(), 1)]);
}

#[test]
fn a_reply_saved_before_a_crash_posts_once() {
    let mut h = Harness::new(default_script());
    h.agents.hold(true);
    h.connect();
    h.add_side(SIDE, BOB);
    h.post_side(SIDE, BOB, "hello chief");
    h.wake(&[(SIDE, 1)]);
    h.step();
    h.agents.wait_prompts(1);
    // The turn started: its message, the floor and the pending turn are saved.
    let mut h = restart(h);
    assert_eq!(h.brain.state().side[SIDE].seq, 1);
    h.connect();
    h.wake(&[(SIDE, 1)]);
    settle_all(&mut h);
    assert_eq!(prompts(&h), 0, "the message is not answered again");
    let sends = h.side_sends(SIDE);
    assert_eq!(sends.len(), 1, "{sends:?}");
    assert!(sends[0].1.starts_with("(interrupted"), "{sends:?}");
    assert_eq!(
        acks(&h),
        vec![(SIDE.to_owned(), 1)],
        "acked after the notice"
    );
    let mut h = restart(h);
    h.connect();
    h.wake(&[(SIDE, 1)]);
    settle_all(&mut h);
    assert_eq!(h.side_sends(SIDE).len(), 1, "the saved reply posts once");
}

/// Requirement 3: a conversation that is closed (its read is refused)
/// loses its floor, and its wake is acked so it is not delivered forever.
#[test]
fn a_closed_side_conversation_loses_its_floor_and_its_wake_is_acked() {
    let dir = tempfile::tempdir().unwrap();
    let mut state = HostState::default();
    state.side.insert(
        "conv_gone".into(),
        SideFloor {
            seq: 3,
            touched_ms: now_ms(),
            ..SideFloor::default()
        },
    );
    StateFile::new(&dir.path().join("host.json"))
        .save(&state)
        .unwrap();
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    h.wake(&[("conv_gone", 4)]);
    settle_all(&mut h);
    assert!(!h.brain.state().side.contains_key("conv_gone"));
    assert_eq!(acks(&h), vec![("conv_gone".to_owned(), 4)]);
    assert_eq!(prompts(&h), 0);
}

/// Requirement 3: floors without a wake for `FLOOR_RETENTION_DAYS` are
/// pruned; recent ones stay.
#[test]
fn side_floors_without_a_wake_for_the_retention_days_are_pruned() {
    let dir = tempfile::tempdir().unwrap();
    let now = now_ms();
    let mut state = HostState::default();
    for (id, age_days) in [("conv_old", FLOOR_RETENTION_DAYS + 1), ("conv_recent", 1)] {
        state.side.insert(
            id.into(),
            SideFloor {
                seq: 5,
                touched_ms: now - age_days * DAY_MS,
                ..SideFloor::default()
            },
        );
    }
    StateFile::new(&dir.path().join("host.json"))
        .save(&state)
        .unwrap();
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, default_script(), owner);
    h.connect();
    let side = &h.brain.state().side;
    assert!(!side.contains_key("conv_old"), "{side:?}");
    assert_eq!(side["conv_recent"].seq, 5);
    // The pruned conversation wakes again later: it starts at that wake.
    h.add_side("conv_old", BOB);
    for text in ["one", "two", "three"] {
        h.post_side("conv_old", BOB, text);
    }
    h.wake(&[("conv_old", 3)]);
    settle_all(&mut h);
    let texts: Vec<String> = h
        .agents
        .inner
        .lock()
        .unwrap()
        .prompts
        .iter()
        .map(|p| p.last().unwrap()["text"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(texts.len(), 1);
    assert!(
        texts[0].contains("three") && !texts[0].contains("one"),
        "{texts:?}"
    );
}
