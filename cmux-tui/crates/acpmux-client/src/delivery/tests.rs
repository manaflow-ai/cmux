use std::collections::BTreeSet;
use std::path::PathBuf;

use super::*;

fn table_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/composer-delivery/table.json")
}

fn rendered() -> String {
    pretty(&table())
}

fn pretty(value: &Value) -> String {
    let mut text = serde_json::to_string_pretty(value).expect("renders");
    text.push('\n');
    text
}

/// The committed replay vectors are the ones `step` walks (same switch as the table).
#[test]
fn committed_vectors_are_current() {
    let path = table_path().with_file_name("vectors.json");
    let now = pretty(&vectors());
    if std::env::var("CMUX_UPDATE_COMPOSER_DELIVERY_TABLE").as_deref() == Ok("1") {
        std::fs::write(&path, &now).expect("write vectors");
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(
        committed == now,
        "{} is stale: rerun with CMUX_UPDATE_COMPOSER_DELIVERY_TABLE=1",
        path.display()
    );
}

/// The table's stale rule holds: under another generation, a transition row's answer is refused
/// stale_generation and a refusal row's with its own refusal.
#[test]
fn the_stale_rule_is_what_step_does() {
    for machine in sample_states() {
        let rows = sample_events(SAMPLE).map(|event| step(&machine, &event));
        for generation in [Generation(SAMPLE.0 - 1), Generation(SAMPLE.0 + 1)] {
            for (event, row) in sample_events(generation).iter().zip(&rows) {
                if event.generation().is_none() {
                    continue;
                }
                let expected = match row {
                    Ok(_) => Refusal::StaleGeneration,
                    Err(refusal) => *refusal,
                };
                assert_eq!(
                    step(&machine, event),
                    Err(expected),
                    "{} {}",
                    machine.delivery.key(),
                    event.kind()
                );
            }
        }
    }
}

/// The committed table is the one `step` answers. `CMUX_UPDATE_COMPOSER_DELIVERY_TABLE=1`
/// rewrites it.
#[test]
fn committed_table_is_current() {
    let path = table_path();
    let now = rendered();
    if std::env::var("CMUX_UPDATE_COMPOSER_DELIVERY_TABLE").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().expect("parent")).expect("schemas dir");
        std::fs::write(&path, &now).expect("write table");
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!("{}: {e}; run with CMUX_UPDATE_COMPOSER_DELIVERY_TABLE=1", path.display())
    });
    assert!(
        committed == now,
        "{} is stale: rerun `CMUX_UPDATE_COMPOSER_DELIVERY_TABLE=1 cargo test -p acpmux-client delivery` and commit it",
        path.display()
    );
}

/// Every key against every event is a transition or a named refusal, and the table holds exactly
/// those pairs.
#[test]
fn every_state_against_every_event_is_decided() {
    let states = sample_states();
    assert_eq!(states.len(), Delivery::KEYS.len());
    let mut pairs = 0;
    for (machine, key) in states.iter().zip(Delivery::KEYS) {
        assert_eq!(machine.delivery.key(), key);
        for (event, kind) in sample_events(SAMPLE).iter().zip(Event::KINDS) {
            assert_eq!(event.kind(), kind);
            pairs += 1;
            if let Ok((after, _)) = step(machine, event) {
                assert!(after.issued >= machine.issued);
                assert!(Delivery::KEYS.contains(&after.delivery.key()));
            }
        }
    }
    let table = table();
    assert_eq!(table["transitions"].as_array().expect("rows").len(), pairs);
    assert_eq!(pairs, Delivery::KEYS.len() * Event::KINDS.len());
}

/// An answer or timer under any generation but the awaited one never moves the machine.
#[test]
fn a_stale_generation_changes_nothing() {
    for machine in sample_states() {
        for generation in [Generation(SAMPLE.0 - 1), Generation(SAMPLE.0 + 1), Generation(0)] {
            for event in sample_events(generation) {
                if event.generation().is_none() {
                    continue;
                }
                assert!(
                    step(&machine, &event).is_err(),
                    "{} {} under {generation:?}",
                    machine.delivery.key(),
                    event.kind()
                );
            }
        }
    }
}

/// The events the exhaustive walk draws from: every intent and acpmux word, and every answer or
/// timer under the generation the machine wrote last and under the one before it (a stale answer).
fn alphabet(machine: &Machine) -> Vec<Event> {
    let now = machine.issued;
    let stale = Generation(now.0.saturating_sub(1));
    let mut events: Vec<Event> =
        sample_events(now).into_iter().filter(|e| e.generation().is_none()).collect();
    for generation in [now, stale] {
        events.extend(sample_events(generation).into_iter().filter(|e| e.generation().is_some()));
    }
    events
}

/// What one walk saw: the writes, which are still unanswered, and the intents acpmux took.
#[derive(Clone, Default)]
struct Ledger {
    writes: u32,
    /// Writes whose answer has not come (no refusal, no "acpmux away", no deadline).
    out: BTreeSet<u64>,
    /// Submits, Retries and host releases the machine accepted.
    send_intents: u32,
    /// acpmux took or the agent read the prompt.
    taken: bool,
    /// Writes since acpmux took it.
    writes_after_taken: u32,
}

/// Checks one step against the invariants, and moves the ledger.
fn check(before: &Machine, event: &Event, result: &Step, ledger: &mut Ledger, path: &[Event]) {
    let Ok((after, effects)) = result else {
        return;
    };
    let sends: Vec<Generation> = effects
        .iter()
        .filter_map(|effect| match effect {
            Effect::SendPrompt { generation } => Some(*generation),
            Effect::ArmTimers { .. } | Effect::ClearTimers => None,
        })
        .collect();
    assert!(sends.len() <= 1, "two writes in one step: {path:?}");
    let intent = matches!(event, Event::Submit | Event::SubmitBehindTurn | Event::Release);
    // Only the person's Send or Retry, or a host hold's release, writes; never an answer, a timer
    // or acpmux's word.
    if !sends.is_empty() {
        assert!(intent, "{} wrote session/prompt: {path:?}", event.kind());
    }
    // Every Send, Retry or host release the machine takes writes exactly one (a trust or wake
    // hold's release hands the prompt back to the composer, whose Send writes it).
    let hands_back =
        matches!(before.delivery, Delivery::Held { hold: Hold::Trust | Hold::MachineWaking });
    if intent && !hands_back {
        assert_eq!(sends.len(), 1, "{} took but wrote nothing: {path:?}", event.kind());
        ledger.send_intents += 1;
    }
    if let Some(generation) = sends.first() {
        assert!(ledger.out.is_empty(), "a second session/prompt while one is out: {path:?}");
        assert_eq!(*generation, after.issued, "a write under an old generation: {path:?}");
        assert!(*generation > before.issued);
        ledger.writes += 1;
        ledger.out.insert(generation.0);
        if ledger.taken {
            ledger.writes_after_taken += 1;
        }
    }
    match event {
        Event::Refused { generation, .. }
        | Event::Unanswered { generation, .. }
        | Event::HostAway { generation }
        | Event::FailTimer { generation } => {
            ledger.out.remove(&generation.0);
        }
        Event::Accepted | Event::Read => {
            ledger.taken = true;
            ledger.out.clear();
        }
        Event::Submit
        | Event::SubmitBehindTurn
        | Event::HoldTrust
        | Event::HoldMachineWaking
        | Event::Release
        | Event::SlowTimer { .. }
        | Event::HandBack => {}
    }
    // Refused at its turn after acpmux took it: it never ran, so Retry may write it again.
    if matches!(after.delivery, Delivery::Failed { cause: FailCause::Refused, .. }) {
        ledger.taken = false;
    }
    assert_eq!(after.delivery.in_flight(), !ledger.out.is_empty(), "in-flight drifted: {path:?}");
    if matches!(after.delivery, Delivery::Delivered { .. } | Delivery::Read { .. }) {
        assert_eq!(ledger.writes_after_taken, 0, "written after acpmux took it: {path:?}");
        assert!(ledger.writes >= 1, "taken without a write: {path:?}");
    }
    assert_eq!(ledger.writes, ledger.send_intents);
    // The data only its state has: a failure's hop and code live on Failed.
    let json = serde_json::to_value(&after.delivery).expect("serializes");
    let failed = matches!(after.delivery, Delivery::Failed { .. });
    assert_eq!(json.get("hop").is_some(), failed);
    assert_eq!(json.get("code").is_some(), failed);
}

/// Every event sequence up to length 6 from a draft, under the current and a stale generation:
/// at most one `session/prompt` is out for the prompt at any time, only Send, Retry or a host
/// release writes one, nothing writes it after acpmux took it, and a sequence whose one write
/// intent is its first Send writes exactly one.
#[test]
fn every_sequence_up_to_six_sends_one_prompt_per_prompt_id() {
    const DEPTH: usize = 6;
    let mut sequences = 0u64;
    let mut stack: Vec<(Machine, Ledger, Vec<Event>)> =
        vec![(Machine::draft(), Ledger::default(), Vec::new())];
    while let Some((machine, ledger, path)) = stack.pop() {
        sequences += 1;
        // Exactly one: a sequence whose one taken send intent is its Send writes one prompt.
        if ledger.send_intents == 1 {
            assert_eq!(ledger.writes, 1, "{path:?}");
        }
        assert_eq!(ledger.writes, ledger.send_intents, "{path:?}");
        if path.len() == DEPTH {
            continue;
        }
        for event in alphabet(&machine) {
            let result = step(&machine, &event);
            let mut path = path.clone();
            path.push(event.clone());
            let mut ledger = ledger.clone();
            check(&machine, &event, &result, &mut ledger, &path);
            let machine = match result {
                Ok((after, _)) => after,
                Err(_) => machine.clone(),
            };
            stack.push((machine, ledger, path));
        }
    }
    println!("composer delivery: {sequences} sequences up to length {DEPTH}");
    assert!(sequences > 1_000_000);
}

/// A seeded random walk, longer than the exhaustive one, from every state.
#[test]
fn seeded_random_walk_keeps_the_invariants() {
    let mut seed: u64 = 0x5eed_0026;
    let mut next = || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    for _ in 0..2_000 {
        let mut machine = Machine::draft();
        let mut ledger = Ledger::default();
        let mut path = Vec::new();
        for _ in 0..64 {
            let events = alphabet(&machine);
            let event = events[(next() % events.len() as u64) as usize].clone();
            path.push(event.clone());
            let result = step(&machine, &event);
            check(&machine, &event, &result, &mut ledger, &path);
            if let Ok((after, _)) = result {
                machine = after;
            }
        }
    }
}

/// Send, acpmux away, back, taken, read: one prompt, two writes of the same frame, the first
/// answered "away".
#[test]
fn a_held_send_goes_once_acpmux_answers() {
    let m = Machine::draft();
    let (m, effects) = step(&m, &Event::Submit).unwrap();
    assert_eq!(
        effects,
        vec![
            Effect::SendPrompt { generation: Generation(1) },
            Effect::ArmTimers { generation: Generation(1) }
        ]
    );
    let (m, _) = step(&m, &Event::HostAway { generation: Generation(1) }).unwrap();
    assert!(m.delivery.held_for_host());
    assert_eq!(m.delivery.word(), Some("sending"));
    assert_eq!(step(&m, &Event::FailTimer { generation: Generation(1) }), Err(Refusal::Held));
    let (m, effects) = step(&m, &Event::Release).unwrap();
    assert_eq!(
        effects,
        vec![
            Effect::SendPrompt { generation: Generation(2) },
            Effect::ArmTimers { generation: Generation(2) }
        ]
    );
    assert!(m.delivery.held_for_host(), "still says Sending when ready");
    assert_eq!(step(&m, &Event::Release), Err(Refusal::InFlight));
    let (m, effects) = step(&m, &Event::Accepted).unwrap();
    assert_eq!(effects, vec![Effect::ClearTimers]);
    let (m, _) = step(&m, &Event::Read).unwrap();
    assert_eq!(m.delivery.key(), "read");
    assert_eq!(step(&m, &Event::Submit), Err(Refusal::AlreadyRead));
}

/// A send that timed out still takes acpmux's late word; a refused one does not.
#[test]
fn only_an_unanswered_failure_takes_a_late_acceptance() {
    let (m, _) = step(&Machine::draft(), &Event::Submit).unwrap();
    let (timed_out, _) = step(&m, &Event::FailTimer { generation: Generation(1) }).unwrap();
    assert_eq!(timed_out.delivery.key(), "failed_unanswered");
    assert!(matches!(&timed_out.delivery, Delivery::Failed { code, .. } if code == TIMEOUT_CODE));
    assert_eq!(step(&timed_out, &Event::Accepted).unwrap().0.delivery.key(), "delivered");
    let refused = Event::Refused {
        generation: Generation(1),
        hop: Hop::Acpmux,
        code: "trust.pending".into(),
    };
    let (refused, _) = step(&m, &refused).unwrap();
    assert_eq!(step(&refused, &Event::Accepted), Err(Refusal::AlreadyRefused));
    let (retry, effects) = step(&refused, &Event::Submit).unwrap();
    assert_eq!(effects[0], Effect::SendPrompt { generation: Generation(2) });
    assert_eq!(retry.delivery, Delivery::Sending { attempt: Generation(2), slow: false });
}

#[test]
fn trust_and_wake_holds_write_nothing_and_go_back_to_the_composer() {
    for hold in [Event::HoldTrust, Event::HoldMachineWaking] {
        let (m, effects) = step(&Machine::draft(), &hold).unwrap();
        assert!(effects.is_empty());
        assert_eq!(m.delivery.word(), None);
        assert_eq!(step(&m, &Event::Submit), Err(Refusal::Held));
        let (m, effects) = step(&m, &Event::Release).unwrap();
        assert!(effects.is_empty());
        assert_eq!(m.delivery, Delivery::Draft);
    }
}

#[test]
fn table_names_its_states_words_and_refusals() {
    let table = table();
    let states = table["states"].as_array().expect("states");
    assert_eq!(states.len(), Delivery::KEYS.len());
    for state in states {
        let word = &state["word"];
        assert!(
            word.is_null()
                || ["sending", "delivered", "read", "failed"].contains(&word.as_str().unwrap())
        );
    }
    assert_eq!(table["refusals"], Value::from(Refusal::ALL.map(Refusal::as_str).to_vec()));
    for row in table["transitions"].as_array().expect("rows") {
        if let Some(refusal) = row.get("refusal") {
            assert!(Refusal::ALL.map(Refusal::as_str).contains(&refusal.as_str().unwrap()));
        }
    }
}
