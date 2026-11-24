//! Fixture tests of the monitor's envelopes and follower: round trips, unknown fields,
//! stale generations, gaps, and redaction.

use super::{attach_params, human};
use crate::cli::monitor_envelope::*;
use serde_json::{Value, json};

fn info() -> Value {
    json!({
        "sessionId": "s1",
        "name": "nightly",
        "title": "a private title",
        "lastPrompt": "a secret prompt",
        "lastMessage": {"role": "user", "text": "secret"},
        "cwd": "/home/someone/private",
        "status": "running",
        "harness": "claude",
        "model": "claude-opus-5-5",
        "pendingPermissions": 1,
        "children": 2,
        "lastSeq": 40,
        "updatedAt": 1_000,
        "sessionReceipt": {"hostId": "local", "muxSessionId": "s1", "agentSessionId": "a", "generation": 7},
        "someFutureField": {"x": 1}
    })
}

fn snap() -> Snapshot {
    Snapshot::from_info(&info(), 3_500, false).unwrap()
}

fn event(generation: u64, sequence: u64) -> Event {
    Event::from_record(
        "s1",
        generation,
        &json!({"seq": sequence, "kind": "agent_message_chunk", "at": 5}),
    )
    .unwrap()
}

#[test]
fn snapshot_from_info_carries_the_cursor_and_redacts() {
    let s = snap();
    assert_eq!(s.cursor, Cursor { generation: 7, sequence: 40 });
    assert_eq!((s.state.as_str(), s.pending_permissions, s.children), ("running", 1, 2));
    assert_eq!(s.freshness.age_ms, Some(2_500));
    assert!(s.redacted && !s.resyncing);
    let line = serde_json::to_string(&Envelope::Snapshot(s)).unwrap();
    for secret in ["secret", "private", "lastPrompt", "cwd"] {
        assert!(!line.contains(secret), "{secret} leaked: {line}");
    }
    assert!(line.contains(r#""type":"snapshot""#) && line.contains(SCHEMA));
}

#[test]
fn snapshot_without_a_generation_or_seq_is_refused_not_guessed() {
    let mut i = info();
    i["sessionReceipt"].as_object_mut().unwrap().remove("generation");
    assert!(Snapshot::from_info(&i, 0, false).is_none());
    let mut i = info();
    i.as_object_mut().unwrap().remove("lastSeq");
    assert!(Snapshot::from_info(&i, 0, false).is_none());
}

#[test]
fn every_envelope_round_trips() {
    let f = Follower::new(&snap());
    let all = [
        Envelope::Snapshot(snap()),
        Envelope::Event(event(7, 41)),
        Envelope::Gap(f.gap(GapReason::Sequence, Some(43))),
        Envelope::Complete(Complete {
            schema: SCHEMA.into(),
            operation_id: "op1".into(),
            session_id: "s1".into(),
            generation: 7,
            state: "completed".into(),
            completed_at: 9,
            children: vec![json!({"index": 0})],
            result_summary: Some("ok".into()),
            error: None,
            receipt_ref: "r1".into(),
        }),
    ];
    for e in all {
        let back: Envelope = serde_json::from_str(&serde_json::to_string(&e).unwrap()).unwrap();
        assert_eq!(back, e);
    }
}

#[test]
fn unknown_fields_and_kinds_are_tolerated() {
    let e: Envelope = serde_json::from_value(json!({
        "type": "event", "id": "s1:41", "sessionId": "s1", "generation": 7, "sequence": 41,
        "kind": "some_kind_from_the_future", "newField": [1, 2]
    }))
    .unwrap();
    let Envelope::Event(e) = e else { panic!("not an event") };
    assert_eq!(e.kind, "some_kind_from_the_future");
    let s: Envelope = serde_json::from_value({
        let mut v = serde_json::to_value(Envelope::Snapshot(snap())).unwrap();
        v["extra"] = json!({"nested": true});
        v["agent"]["extra"] = json!(1);
        v
    })
    .unwrap();
    assert!(matches!(s, Envelope::Snapshot(_)));
}

#[test]
fn malformed_envelopes_are_rejected() {
    assert!(
        serde_json::from_value::<Envelope>(json!({"type": "event", "sessionId": "s1"})).is_err()
    );
    assert!(serde_json::from_value::<Envelope>(json!({"type": "nope"})).is_err());
    assert!(
        serde_json::from_value::<Envelope>(json!({
            "type": "event", "id": "s1:1", "sessionId": "s1", "generation": "seven", "sequence": 1,
            "kind": "k"
        }))
        .is_err()
    );
}

#[test]
fn follower_applies_in_order_and_skips_repeats() {
    let mut f = Follower::new(&snap());
    assert_eq!(f.accept(&event(7, 41)), Step::Apply);
    assert_eq!(f.accept(&event(7, 42)), Step::Apply);
    assert_eq!(f.accept(&event(7, 42)), Step::Duplicate);
    assert_eq!(f.accept(&event(7, 10)), Step::Duplicate);
    assert_eq!(f.cursor, Cursor { generation: 7, sequence: 42 });
}

#[test]
fn follower_rejects_a_stale_generation() {
    let mut f = Follower::new(&snap());
    assert_eq!(f.accept(&event(6, 41)), Step::Stale);
    assert_eq!(f.cursor, Cursor { generation: 7, sequence: 40 });
}

#[test]
fn follower_reports_a_sequence_gap_and_keeps_its_cursor() {
    let mut f = Follower::new(&snap());
    let Step::Gap(g) = f.accept(&event(7, 43)) else { panic!("no gap") };
    assert_eq!((g.reason, g.got, g.state.as_str()), (GapReason::Sequence, Some(43), "resyncing"));
    assert_eq!(g.cursor, Cursor { generation: 7, sequence: 40 });
    assert_eq!(f.cursor.sequence, 40);
}

#[test]
fn follower_reports_a_new_generation() {
    let mut f = Follower::new(&snap());
    let Step::Gap(g) = f.accept(&event(8, 1)) else { panic!("no gap") };
    assert_eq!((g.reason, g.got), (GapReason::Generation, Some(8)));
    assert!(f.check_generation(7).is_none());
    assert_eq!(f.check_generation(9).map(|g| g.reason), Some(GapReason::Generation));
}

#[test]
fn resync_snapshot_restarts_the_cursor() {
    let mut i = info();
    i["sessionReceipt"]["generation"] = json!(8);
    i["lastSeq"] = json!(3);
    let s = Snapshot::from_info(&i, 4_000, true).unwrap();
    assert!(s.resyncing);
    let mut f = Follower::new(&s);
    assert_eq!(f.accept(&event(8, 4)), Step::Apply);
    assert!(human(&Envelope::Snapshot(s)).starts_with("snapshot (resyncing) nightly running"));
}

#[test]
fn event_records_are_redacted_to_kind_time_and_status() {
    let rec = json!({
        "seq": 41, "at": 9, "dir": "in", "kind": "agent_message_chunk", "sessionId": "s1",
        "msg": {"params": {"update": {"content": {"text": "a secret reply"}}}}
    });
    let e = Event::from_record("s1", 7, &rec).unwrap();
    let line = serde_json::to_string(&Envelope::Event(e)).unwrap();
    assert!(!line.contains("secret") && !line.contains("msg"), "{line}");
    let status = json!({"seq": 42, "kind": "status", "msg": {"status": "idle", "turns": 2}});
    let e = Event::from_record("s1", 7, &status).unwrap();
    assert_eq!((e.id.as_str(), e.state.as_deref()), ("s1:42", Some("idle")));
    assert!(Event::from_record("s1", 7, &json!({"kind": "status"})).is_none());
}

#[test]
fn the_subscription_is_hidden_and_takes_no_history() {
    let p = attach_params("s1");
    assert_eq!(p, json!({"sessionId": "s1", "limit": 0, "visible": false}));
}

#[test]
fn the_monitor_connects_without_a_caller_and_sends_no_writes() {
    // With a caller, the daemon ties `_acpmux/events` reads to it: a parent monitoring its
    // lane would mark the lane's report read and drop it from its own queue.
    let src = include_str!("monitor.rs");
    let code = src.split("#[cfg(test)]").next().unwrap();
    assert!(code.contains("connect_without_caller(false)"));
    assert!(!code.contains("daemon::connect("), "the monitor must not connect with a caller");
    for write in ["SESSION_PROMPT", "SESSION_CANCEL", "MUX_SEND", "PERMISSION", "MUX_KILL"] {
        assert!(!code.contains(write), "the monitor must not send {write}");
    }
    let methods: Vec<&str> = code.match_indices("method::").map(|(i, _)| &code[i..]).collect();
    for m in methods {
        let name: String = m["method::".len()..]
            .chars()
            .take_while(|c| c.is_ascii_uppercase() || *c == '_')
            .collect();
        assert!(
            ["MUX_ATTACH", "MUX_EVENTS", "MUX_INFO", "MUX_DISCONNECTED", ""]
                .contains(&name.as_str()),
            "unexpected method {name}"
        );
    }
}
