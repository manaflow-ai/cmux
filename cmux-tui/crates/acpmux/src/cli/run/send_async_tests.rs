use super::*;

/// The process's exit status for a send's outcome, as `errors::exit_with` gives it.
fn exit_of(r: &Result<Handoff>) -> i32 {
    match r {
        Ok(_) => 0,
        Err(e) => errors::classify(e).exit_status(),
    }
}

fn delivered(accepted: Value) -> Value {
    json!({"status": "delivered", "accepted": accepted})
}

/// Every hand-off exits 0 and opens with `sent STATE id=ID to=TARGET`, in text and as
/// `--json`'s `ok`, `state` and `id`: queued in the outbox (the target busy or its machine
/// down), held in an idle receiver's inbox, delivered, or steered into a running turn.
#[test]
fn each_hand_off_exits_0_and_opens_with_its_state() {
    let queued = json!({"deliveryId": "d1"});
    let cases = [
        (queued.clone(), json!({"status": "queued"}), "queued"),
        (queued.clone(), json!({"status": "delivering"}), "queued"),
        (
            json!({"deliveryId": "d1", "hostUnreachable": true}),
            json!({"status": "queued"}),
            "queued",
        ),
        (queued.clone(), json!({"status": "queued", "error": "peer_unreachable"}), "queued"),
        (queued.clone(), delivered(json!({"heldInInbox": true})), "held"),
        (queued.clone(), delivered(json!({"heldInInbox": true, "steer": true})), "held"),
        (queued.clone(), delivered(json!({"steer": true})), "steered"),
        (queued.clone(), delivered(json!({"steer": false})), "delivered"),
        (queued.clone(), delivered(Value::Null), "delivered"),
    ];
    for (queued, status, want) in cases {
        let r = handed_off("gcp-agent-lane-1/lane", &queued, &status);
        assert_eq!(exit_of(&r), 0, "{status}");
        let handoff = r.unwrap();
        assert_eq!(handoff.state.name(), want, "{status}");
        let lines = handoff_lines(&handoff, "gcp-agent-lane-1/lane", "d1", &status, false);
        assert_eq!(lines[0], format!("sent {want} id=d1 to=gcp-agent-lane-1/lane"), "{status}");
        assert!(lines.len() >= 2, "the human line follows: {lines:?}");
        let out = handoff_json(&handoff, "gcp-agent-lane-1/lane", "d1", "p1", &status, false);
        assert_eq!(
            (&out["ok"], &out["state"], &out["id"]),
            (&json!(true), &json!(want), &json!("d1")),
            "{out}"
        );
    }
}

/// The human wording stays after the stable line: what each state means for a person.
#[test]
fn the_human_line_follows_the_stable_one() {
    let held = delivered(json!({"heldInInbox": true}));
    let h = handed_off("lane", &json!({}), &held).unwrap();
    let lines = handoff_lines(&h, "lane", "d2", &held, false);
    assert_eq!(lines[1], format!("{} (delivery d2)", super::super::super::output::HELD_LINE));
    let down = json!({"status": "queued"});
    let h = handed_off("lane", &json!({"hostUnreachable": true}), &down).unwrap();
    assert!(
        handoff_lines(&h, "lane", "d3", &down, false)[1]
            .starts_with("queued; host unreachable, will retry (delivery d3;")
    );
    let steered = delivered(json!({"steer": true, "replaced": 2}));
    let h = handed_off("lane", &json!({}), &steered).unwrap();
    assert_eq!(
        handoff_lines(&h, "lane", "d4", &steered, true),
        ["sent steered id=d4 to=lane", "steered (delivery d4)", "replaced 2 queued"]
    );
}

/// A refusal the target gave at once exits nonzero and prints no `sent` line: 4 for no such
/// session, 7 for any other (a paused or full pair is the outbox's `held`, not an inbox's).
#[test]
fn a_refusal_exits_4_or_7() {
    let no_session = json!({"status": "failed", "reason": "no_session",
        "error": "no_session: no session proc-title on host; did you mean: feed-lane"});
    assert_eq!(exit_of(&handed_off("host/proc-title", &json!({}), &no_session)), 4);
    let refused = json!({"status": "failed", "error": "folder is not trusted"});
    let r = handed_off("lane", &json!({}), &refused);
    assert_eq!(exit_of(&r), 7);
    let app = errors::classify(r.as_ref().unwrap_err());
    assert_eq!((app.code.name(), app.message.as_str()), ("refused", "folder is not trusted"));
    let paused = json!({"status": "held", "reason": "pair_paused", "error": "the pair is paused"});
    let r = handed_off("lane", &json!({}), &paused);
    assert_eq!(exit_of(&r), 7);
    assert_eq!(errors::classify(r.as_ref().unwrap_err()).detail, "pair_paused");
    assert_eq!(exit_of(&handed_off("lane", &json!({}), &json!({"status": "failed"}))), 7);
}

#[test]
fn a_delivery_with_no_such_session_reads_failed_no_session() {
    let v = json!({"pending": 0, "deliveries": [
        {"deliveryId": "d3", "target": "host/proc-title", "status": "failed", "attempts": 1,
         "createdAt": 10_000, "reason": "no_session",
         "error": "no_session: no session proc-title on host; did you mean: feed-lane"},
    ]});
    assert_eq!(
        list_lines(&v, 70_000)[1],
        "failed: no_session  host/proc-title  60s ago  attempt 1  d3  last error: no_session: no session proc-title on host; did you mean: feed-lane"
    );
    assert_eq!(state_label(&json!({"status": "queued", "reason": null})), "queued");
}

#[test]
fn list_lines_show_state_target_age_and_the_waiting_ones_error() {
    assert_eq!(
        list_lines(&json!({"deliveries": []}), 0),
        ["no messages queued or sent in the last day"]
    );
    let v = json!({"pending": 1, "deliveries": [
        {"deliveryId": "d2", "target": "gcp-agent-lane-1/lane", "status": "queued", "attempts": 3,
         "createdAt": 10_000, "error": "peer_unreachable"},
        {"deliveryId": "d1", "target": "lane", "status": "delivered", "attempts": 1,
         "createdAt": 1_000, "error": null},
    ]});
    assert_eq!(
        list_lines(&v, 70_000),
        [
            "1 waiting, 2 in all",
            "queued      gcp-agent-lane-1/lane  60s ago  attempt 3  d2  last error: peer_unreachable",
            "delivered   lane  69s ago  attempt 1  d1",
        ]
    );
}
