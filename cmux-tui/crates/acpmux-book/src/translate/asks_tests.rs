//! Ask rows (decision 245): opened by a request, settled by its decision.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects,
    reason = "deterministic inputs and assertions"
)]
use super::*;

fn mux(seq: u64, kind: &str, msg: &str) -> String {
    format!(r#"{{"seq":{seq},"at":1000,"dir":"mux","kind":"{kind}","msg":{msg}}}"#)
}
fn run(state: &mut State, lines: &[String]) -> Vec<Op> {
    let mut ops = Vec::new();
    for line in lines {
        ops.extend(translate(state, Harness::V1, 0, 1, line.as_bytes()).unwrap());
    }
    ops
}
/// Every ask row op, in order: whether it is open, its fields.
fn asks(ops: &[Op]) -> Vec<(u64, bool, BTreeMap<String, String>)> {
    ops.iter()
        .filter_map(|op| match &op.change {
            Change::Row(row) if row.kind == RowKind::Ask => {
                Some((row.id, row.open, row.fields.clone()))
            }
            _ => None,
        })
        .collect()
}
fn settled(ops: &[Op]) -> BTreeMap<String, String> {
    let rows: Vec<_> = asks(ops).into_iter().filter(|(_, open, _)| !open).collect();
    assert_eq!(rows.len(), 1, "one settled ask: {rows:?}");
    rows.into_iter().next().unwrap().2
}
fn body_fields(ops: &[Op], id: u64) -> Vec<BodyField> {
    ops.iter()
        .filter_map(|op| match &op.change {
            Change::Body { id: of, field, .. } if *of == id => Some(*field),
            _ => None,
        })
        .collect()
}
const OPTIONS: &str = r#"[{"optionId":"once","name":"Allow","kind":"allow_once"},{"optionId":"always","name":"Always","kind":"allow_always"},{"optionId":"no","name":"Deny","kind":"reject_once"},{"optionId":"chat","name":"Allow chat"},{"optionId":"this","name":"Allow for this chat"},{"optionId":"plan","name":"Use the plan","kind":"other"}]"#;
fn request(id: &str) -> String {
    format!(
        r#"{{"permissionId":"{id}","groupId":null,"turnId":"t1","agentRequestId":4,"request":{{"toolCall":{{"toolCallId":"c1","title":"  Run make  ","kind":"execute"}},"options":{OPTIONS}}}}}"#
    )
}
fn decide(id: &str, option: &str) -> String {
    format!(
        r#"{{"permissionId":"{id}","outcome":{{"outcome":"selected","optionId":"{option}"}},"answeredBy":{{"id":"tailnet:ana","name":"Ana","avatar":"https://x/a.png"}}}}"#
    )
}

#[test]
fn a_permission_opens_an_ask_row_its_decision_settles() {
    let mut state = State::default();
    let ops = run(&mut state, &[mux(1, "permission_request", &request("p1"))]);
    let (id, open, fields) = asks(&ops).into_iter().next().unwrap();
    assert!(open);
    assert_eq!(
        fields,
        BTreeMap::from([
            ("ask".to_owned(), "\"permission\"".to_owned()),
            ("permissionId".to_owned(), "\"p1\"".to_owned()),
            ("turnId".to_owned(), "\"t1\"".to_owned()),
            ("title".to_owned(), "\"Run make\"".to_owned()),
            ("toolCallId".to_owned(), "\"c1\"".to_owned()),
        ])
    );
    assert_eq!(body_fields(&ops, id), [BodyField::Request]);
    assert_eq!(state.open_rows().filter(|row| row.kind == RowKind::Ask).count(), 1);
    let ops = run(&mut state, &[mux(2, "permission_decision", &decide("p1", "once"))]);
    let fields = settled(&ops);
    assert_eq!(fields["decision"], r#"{"kind":"allowed"}"#);
    // A person's answer names them; an https picture is no participant's here (links are an
    // author's alone).
    assert_eq!(fields["answeredBy"], r#"{"id":"tailnet:ana","name":"Ana"}"#);
    assert_eq!(body_fields(&ops, id), [BodyField::Outcome]);
    assert_eq!(state.open_rows().filter(|row| row.kind == RowKind::Ask).count(), 0);
}

#[test]
fn each_option_kind_reads_as_the_views_decision() {
    for (option, decision) in [
        ("always", r#"{"kind":"allowedAlways"}"#),
        ("no", r#"{"kind":"denied"}"#),
        ("chat", r#"{"kind":"allowedAlways"}"#),
        // The view reads `allow[_ -]?(chat|session)` only: other words between are an answer.
        ("this", r#"{"kind":"answered","option":"this"}"#),
        ("plan", r#"{"kind":"answered","option":"plan"}"#),
        ("gone", r#"{"kind":"answered","option":"gone"}"#),
    ] {
        let mut state = State::default();
        let ops = run(
            &mut state,
            &[
                mux(1, "permission_request", &request("p")),
                mux(2, "permission_decision", &decide("p", option)),
            ],
        );
        assert_eq!(settled(&ops)["decision"], decision, "{option}");
    }
    // Withdrawn by the agent, or answered by a session or a device: cancelled, no person.
    let mut state = State::default();
    let cancel = r#"{"permissionId":"p","outcome":{"outcome":"cancelled"},"answeredBy":{"session":"s","name":"coord"}}"#;
    let ops = run(
        &mut state,
        &[
            mux(1, "permission_request", &request("p")),
            mux(2, "permission_withdrawn", r#"{"agentRequestId":4}"#),
            mux(3, "permission_decision", cancel),
        ],
    );
    let fields = settled(&ops);
    assert_eq!(fields["decision"], r#"{"kind":"cancelled"}"#);
    assert!(!fields.contains_key("answeredBy"));
    // A question is an ask of its own kind; its items stay in its request.
    let mut state = State::default();
    let question = r#"{"permissionId":"q","request":{"toolCall":{"title":"Pick","_meta":{"acpmux":{"question":{"harness":"claude","items":[]}}}},"options":[]}}"#;
    let ops = run(&mut state, &[mux(1, "permission_request", question)]);
    assert_eq!(asks(&ops)[0].2["ask"], "\"question\"");
    // A switch to full access settles the ask it was shown for.
    let auto =
        r#"{"permissionId":"q","policy":"mode","optionId":"x","fullAccess":"bypassPermissions"}"#;
    let ops = run(&mut state, &[mux(2, "permission_auto", auto)]);
    assert_eq!(settled(&ops)["decision"], r#"{"kind":"fullAccess","mode":"bypassPermissions"}"#);
}

#[test]
fn a_secret_and_an_elevation_ask_with_their_caps_counted() {
    let mut state = State::default();
    let ops = run(
        &mut state,
        &[mux(
            1,
            "secret_request",
            r#"{"secretId":"s1","name":"GITHUB_TOKEN","reason":"push the branch"}"#,
        )],
    );
    let fields = &asks(&ops)[0].2;
    assert_eq!(fields["ask"], "\"secret\"");
    assert_eq!(fields["name"], "\"GITHUB_TOKEN\"");
    assert_eq!(fields["reason"], "\"push the branch\"");
    let ops =
        run(&mut state, &[mux(2, "secret_decision", r#"{"secretId":"s1","outcome":"provided"}"#)]);
    assert_eq!(settled(&ops)["decision"], r#"{"kind":"provided"}"#);
    // An elevation: its command (at most 16 words, 1 KB), its host, its time limit, each cut counted.
    let mut state = State::default();
    let argv: Vec<String> = (0..20).map(|n| format!("\"w{n}\"")).collect();
    let reason = "r".repeat(600);
    let elevation = format!(
        r#"{{"secretId":"e1","argv":[{}],"reason":"{reason}","host":"{}","timeoutSecs":300}}"#,
        argv.join(","),
        "h".repeat(70)
    );
    let ops = run(&mut state, &[mux(1, "elevation_request", &elevation)]);
    let fields = &asks(&ops)[0].2;
    assert_eq!(fields["name"], "\"sudo\"");
    let words: Vec<String> = serde_json::from_str(&fields["argv"]).unwrap();
    assert_eq!(words.len(), 16);
    assert_eq!(serde_json::from_str::<String>(&fields["reason"]).unwrap().len(), 512);
    assert_eq!(serde_json::from_str::<String>(&fields["host"]).unwrap().len(), 64);
    assert_eq!(fields["timeoutSecs"], "300");
    assert_eq!(state.counters().cut_fields, 3);
    let ops =
        run(&mut state, &[mux(2, "elevation_decision", r#"{"secretId":"e1","outcome":"denied"}"#)]);
    assert_eq!(settled(&ops)["decision"], r#"{"kind":"denied"}"#);
}

#[test]
fn past_32_open_the_oldest_settles_undecided_and_a_late_decision_is_counted() {
    let mut state = State::default();
    let lines: Vec<String> =
        (0..33).map(|n| mux(n + 1, "permission_request", &request(&format!("p{n}")))).collect();
    let ops = run(&mut state, &lines);
    let forced: Vec<_> = asks(&ops).into_iter().filter(|(_, open, _)| !open).collect();
    assert_eq!(forced.len(), 1);
    assert_eq!(forced[0].2["permissionId"], "\"p0\"");
    assert!(!forced[0].2.contains_key("decision"), "undecided");
    assert_eq!(state.counters().forced_asks, 1);
    assert_eq!(state.open_rows().filter(|row| row.kind == RowKind::Ask).count(), 32);
    // All 32 fit the translator's segment.
    state.checkpoint().unwrap();
    // The decision of the one it settled, and of one never asked, are counted, not lost.
    let ops = run(
        &mut state,
        &[
            mux(40, "permission_decision", &decide("p0", "once")),
            mux(41, "permission_decision", &decide("zz", "once")),
        ],
    );
    assert!(asks(&ops).is_empty());
    assert_eq!(state.counters().unplaced_decisions, 2);
}

#[test]
fn an_open_ask_is_decided_after_a_restart() {
    let mut state = State::default();
    run(&mut state, &[mux(1, "permission_request", &request("p1"))]);
    let mut state = state.checkpoint().unwrap().restore().unwrap();
    assert_eq!(state.open_rows().filter(|row| row.kind == RowKind::Ask).count(), 1);
    let ops = run(&mut state, &[mux(2, "permission_decision", &decide("p1", "no"))]);
    assert_eq!(settled(&ops)["decision"], r#"{"kind":"denied"}"#);
    // Asked again after the hub restarted: its row is open already, so it opens no second one.
    let mut state = State::default();
    let ops = run(
        &mut state,
        &[
            mux(1, "permission_request", &request("p1")),
            mux(2, "permission_reissued", &request("p1")),
        ],
    );
    assert_eq!(asks(&ops).len(), 1);
}

#[test]
fn a_policys_answer_before_its_request_is_not_counted_and_an_option_past_8_is() {
    // The hub writes a policy's answer before the request it answers; the request then opens
    // its ask. Only a person's or a secret's decision for no open ask is counted.
    let mut state = State::default();
    let auto = r#"{"permissionId":"p","policy":"rule","optionId":"once"}"#;
    run(
        &mut state,
        &[mux(1, "permission_auto", auto), mux(2, "permission_request", &request("p"))],
    );
    assert_eq!(state.counters().unplaced_decisions, 0);
    run(&mut state, &[mux(3, "secret_decision", r#"{"secretId":"none","outcome":"provided"}"#)]);
    assert_eq!(state.counters().unplaced_decisions, 1);
    // Ten options: the two past the 8 kept read as answers, and the cut is counted.
    let mut state = State::default();
    let options: Vec<String> = (0..10)
        .map(|n| format!(r#"{{"optionId":"o{n}","name":"Allow {n}","kind":"allow_once"}}"#))
        .collect();
    let ask = format!(
        r#"{{"permissionId":"p","request":{{"toolCall":{{"title":"t"}},"options":[{}]}}}}"#,
        options.join(",")
    );
    run(&mut state, &[mux(1, "permission_request", &ask)]);
    assert_eq!(state.counters().cut_fields, 1);
    let ops = run(&mut state, &[mux(2, "permission_decision", &decide("p", "o9"))]);
    assert_eq!(settled(&ops)["decision"], r#"{"kind":"answered","option":"o9"}"#);
}
