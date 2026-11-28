//! What a user row says of its prompt and its sender, and a turn end a prompt sent now went on
//! under (decisions 231, 236).
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
fn prompt(seq: u64, id: &str) -> String {
    mux(seq, "user_message", &format!(r#"{{"promptId":"{id}","turnId":"{id}","text":"q"}}"#))
}
/// The rows and patches of the turn-end notice, in order: whether each is a patch, and its fields.
fn turn_ends(ops: &[Op]) -> Vec<(bool, u32, BTreeMap<String, String>)> {
    ops.iter()
        .filter_map(|op| match &op.change {
            Change::Row(row) | Change::Patch(row)
                if !row.open
                    && row.fields.get("notice").map(String::as_str) == Some("\"turn_result\"") =>
            {
                Some((matches!(op.change, Change::Patch(_)), row.rev, row.fields.clone()))
            }
            _ => None,
        })
        .collect()
}
/// The settled user row of `id`, as the row op last wrote it.
fn user_row(ops: &[Op], id: &str) -> BTreeMap<String, String> {
    let promptid = format!("\"{id}\"");
    let rows: Vec<_> = ops
        .iter()
        .filter_map(|op| match &op.change {
            Change::Row(row)
                if row.kind == RowKind::User
                    && !row.open
                    && row.fields.get("promptId") == Some(&promptid) =>
            {
                Some(row.fields.clone())
            }
            _ => None,
        })
        .collect();
    rows.last().cloned().unwrap_or_else(|| panic!("no settled user row of {id}: {ops:?}"))
}
/// A turn `p` runs; `q` is queued and sent now; the turn ends `status`.
fn sent_now(status: &str) -> Vec<String> {
    vec![
        prompt(1, "p"),
        mux(2, "queued", r#"{"text":"now","promptId":"q"}"#),
        mux(3, "queue_order", r#"{"promptId":"q","next":true,"order":["q"]}"#),
        mux(4, "turn_result", &format!(r#"{{"turnId":"p","status":"{status}"}}"#)),
    ]
}

#[test]
fn a_prompt_sent_now_carries_the_turn_it_ended_on() {
    let mut state = State::default();
    let mut lines = sent_now("cancelled");
    lines.push(mux(5, "dequeued", r#"{"promptId":"q"}"#));
    lines.push(prompt(6, "q"));
    let ops = run(&mut state, &lines);
    let ends = turn_ends(&ops);
    assert_eq!(ends.len(), 1, "no patch: {ends:?}");
    assert_eq!(ends[0].2["continued"], "true");
    assert_eq!(user_row(&ops, "q")["continues"], "true");
    assert!(!user_row(&ops, "p").contains_key("continues"));
}

#[test]
fn the_continuation_holds_across_a_restart() {
    let mut state = State::default();
    let ops = run(&mut state, &sent_now("completed"));
    assert_eq!(turn_ends(&ops)[0].2["continued"], "true");
    let mut state = state.checkpoint().unwrap().restore().unwrap();
    let ops = run(&mut state, &[prompt(5, "q")]);
    assert_eq!(user_row(&ops, "q")["continues"], "true");
    // And its withdrawal after a restart takes the mark back.
    let mut state = State::default();
    run(&mut state, &sent_now("completed"));
    let mut state = state.checkpoint().unwrap().restore().unwrap();
    let ops = run(&mut state, &[mux(5, "queue_removed", r#"{"promptId":"q"}"#)]);
    let ends = turn_ends(&ops);
    assert_eq!(ends.len(), 1);
    assert!(ends[0].0 && !ends[0].2.contains_key("continued"), "{ends:?}");
}

#[test]
fn each_way_a_prompt_sent_now_never_runs_takes_the_mark_back() {
    for (kind, then) in [
        ("queue_removed", mux(5, "queue_removed", r#"{"promptId":"q"}"#)),
        ("queue_declined", mux(5, "queue_declined", r#"{"promptId":"q"}"#)),
        ("prompt_refused", mux(5, "prompt_refused", r#"{"promptId":"q"}"#)),
        // An older writer's withdrawals.
        ("retracted", mux(5, "retracted", r#"{"promptId":"q"}"#)),
        ("removed", mux(5, "removed", r#"{"promptId":"q"}"#)),
        ("another prompt first", prompt(5, "r")),
    ] {
        let mut state = State::default();
        let mut lines = sent_now("cancelled");
        lines.push(then);
        let ops = run(&mut state, &lines);
        let ends = turn_ends(&ops);
        assert_eq!(ends.len(), 2, "{kind}: {ends:?}");
        let (settled, patch) = (&ends[0], &ends[1]);
        assert!(!settled.0 && settled.2.contains_key("continued"), "{kind}");
        assert!(patch.0, "{kind}: a patch");
        assert_eq!(patch.1, settled.1 + 1, "{kind}: its rev rises");
        let mut expected = settled.2.clone();
        expected.remove("continued");
        assert_eq!(patch.2, expected, "{kind}: the same notice without the mark");
        // The prompt that never ran, run after all, continues nothing.
        let ops = run(&mut state, &[prompt(9, "q")]);
        assert!(!user_row(&ops, "q").contains_key("continues"), "{kind}");
        assert!(turn_ends(&ops).iter().all(|end| !end.0), "{kind}: one patch only");
    }
    // `dequeued` runs it: nothing is taken back.
    let mut state = State::default();
    let mut lines = sent_now("cancelled");
    lines.push(mux(5, "dequeued", r#"{"promptId":"q"}"#));
    assert_eq!(turn_ends(&run(&mut state, &lines)).len(), 1);
}

#[test]
fn a_failed_turn_a_stop_or_an_early_run_writes_no_continuation() {
    // A failed turn shows as failed.
    let mut state = State::default();
    let ops = run(&mut state, &sent_now("failed"));
    assert!(!turn_ends(&ops)[0].2.contains_key("continued"));
    // After a Stop the hub took, the turn's end is the Stop's.
    let mut state = State::default();
    let lines = [
        prompt(1, "p"),
        mux(2, "queued", r#"{"text":"now","promptId":"q"}"#),
        mux(3, "stopping", r#"{"turnId":"p"}"#),
        mux(4, "queue_order", r#"{"promptId":"q","next":true,"order":["q"]}"#),
        mux(5, "turn_result", r#"{"turnId":"p","status":"cancelled"}"#),
    ];
    assert!(!turn_ends(&run(&mut state, &lines))[0].2.contains_key("continued"));
    // A prompt sent now that ran as a steer before the turn ended stopped nothing.
    let mut state = State::default();
    let lines = [
        prompt(1, "p"),
        mux(2, "queued", r#"{"text":"now","promptId":"q"}"#),
        mux(3, "queue_order", r#"{"promptId":"q","next":true,"order":["q"]}"#),
        mux(4, "user_message", r#"{"promptId":"q","turnId":"p","text":"now","steer":true}"#),
        mux(5, "turn_result", r#"{"turnId":"p","status":"completed"}"#),
    ];
    assert!(!turn_ends(&run(&mut state, &lines))[0].2.contains_key("continued"));
    // Sent now with no turn running: nothing to go on under.
    let mut state = State::default();
    let lines = [
        mux(1, "queued", r#"{"text":"now","promptId":"q"}"#),
        mux(2, "queue_order", r#"{"promptId":"q","next":true,"order":["q"]}"#),
        prompt(3, "q"),
        mux(4, "turn_result", r#"{"turnId":"q","status":"completed"}"#),
    ];
    let ops = run(&mut state, &lines);
    assert!(!turn_ends(&ops)[0].2.contains_key("continued"));
    assert!(!user_row(&ops, "q").contains_key("continues"));
}

/// Every op of `lines`, each line at place `100 * (its index + 1)`.
fn run_placed(state: &mut State, lines: &[String]) -> Vec<Op> {
    let mut ops = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        let place = 100 * (index as u64 + 1);
        ops.extend(translate(state, Harness::V1, place, 1, line.as_bytes()).unwrap());
    }
    ops
}
fn bodies(ops: &[Op], id: u64) -> Vec<(BodyField, BodySource)> {
    ops.iter()
        .filter_map(|op| match &op.change {
            Change::Body { id: of, field, source, .. } if *of == id => {
                Some((*field, source.clone()))
            }
            _ => None,
        })
        .collect()
}
fn group(ops: &[Op]) -> BTreeMap<String, String> {
    ops.iter()
        .find_map(|op| match &op.change {
            Change::Row(row) if row.kind == RowKind::Group => Some(row.fields.clone()),
            _ => None,
        })
        .unwrap()
}

#[test]
fn a_user_row_names_its_prompt_its_person_and_their_client() {
    let mut state = State::default();
    let said = r#"{"promptId":"p","turnId":"p","text":"hello","client":"acpmux-cli#12@build-host","agentText":{"from":"  coord  ","signals":["x"]},"inlineParts":[{"kind":"text","text":"hello"}],"pasted":[{"start":0,"end":5}],"_meta":{"provenance":{"kind":"person_message","from":" tailnet:ana ","fromName":"Ana\u200b \n Lee","fromAvatar":"https://lh3.example.com/a.png"}}}"#;
    let ops = run(&mut state, &[mux(1, "user_message", said)]);
    let row = user_row(&ops, "p");
    assert_eq!(row["promptId"], "\"p\"");
    assert_eq!(
        row["author"],
        r#"{"avatar":"https://lh3.example.com/a.png","id":"tailnet:ana","name":"Ana Lee"}"#
    );
    assert_eq!(row["viaCli"], "\"build-host\"");
    assert_eq!(row["agentText"], r#"{"from":"coord"}"#);
    assert!(!row.contains_key("from") && !row.contains_key("steerPromptId"));
    let id = ops
        .iter()
        .find_map(|op| match &op.change {
            Change::Row(row) if row.kind == RowKind::User => Some(row.id),
            _ => None,
        })
        .unwrap();
    let fields: Vec<_> = bodies(&ops, id).into_iter().map(|(field, _)| field).collect();
    assert_eq!(fields, [BodyField::Content, BodyField::InlineParts, BodyField::Pasted]);
}

#[test]
fn another_agents_message_names_no_person_client_or_agent_text() {
    let mut state = State::default();
    let said = r#"{"promptId":"m","turnId":"m","text":"hi","client":"acpmux-cli#1@lane-3","agentText":{},"_meta":{"provenance":{"kind":"agent_message","from":"tailnet:ana","fromName":"Ana"}}}"#;
    let row = user_row(&run(&mut state, &[mux(1, "user_message", said)]), "m");
    for key in ["author", "viaCli", "agentText"] {
        assert!(!row.contains_key(key), "{key}: {row:?}");
    }
    // The Chief's message to a subagent says so; an outbox client, a bare agentText and an
    // unstamped prompt read as the view reads them.
    let mut state = State::default();
    let said = r#"{"promptId":"optchat-tell:7","turnId":"t","text":"go","client":"acpmux-outbox#9@host.a_b-c","agentText":{"from":" "}}"#;
    let row = user_row(&run(&mut state, &[mux(1, "user_message", said)]), "optchat-tell:7");
    assert_eq!(row["from"], "\"chief\"");
    assert_eq!(row["viaCli"], "\"host.a_b-c\"");
    assert_eq!(row["agentText"], "{}");
    assert!(!row.contains_key("author"));
    // A client that is no `acpmux send`, and a person with no id, name none.
    let mut state = State::default();
    let said = r#"{"promptId":"q","turnId":"q","text":"x","client":"cmux-app#1@mac","_meta":{"provenance":{"kind":"person_message","fromName":"Ana"}}}"#;
    let row = user_row(&run(&mut state, &[mux(1, "user_message", said)]), "q");
    assert!(!row.contains_key("viaCli") && !row.contains_key("author"), "{row:?}");
}

#[test]
fn a_waiting_steer_names_its_prompt_until_it_is_read() {
    let mut state = State::default();
    let ops = run(
        &mut state,
        &[
            prompt(1, "p"),
            mux(2, "user_message", r#"{"promptId":"s","turnId":"p","text":"also","steer":true}"#),
        ],
    );
    let open = ops
        .iter()
        .rev()
        .find_map(|op| match &op.change {
            Change::Row(row) if row.kind == RowKind::User && row.open => Some(row.fields.clone()),
            _ => None,
        })
        .unwrap();
    assert_eq!(open["steerPromptId"], "\"s\"");
    let ops = run(&mut state, &[mux(3, "steer_read", r#"{"promptId":"s"}"#)]);
    assert!(!user_row(&ops, "s").contains_key("steerPromptId"));
    // A steer taken back before it was read goes.
    let mut state = State::default();
    run(
        &mut state,
        &[
            prompt(1, "p"),
            mux(2, "user_message", r#"{"promptId":"w","turnId":"p","text":"no","steer":true}"#),
        ],
    );
    let ops = run(&mut state, &[mux(3, "steer_withdrawn", r#"{"promptId":"w"}"#)]);
    // A prompt that never ran leaves by the leave op, never as a settled row.
    assert!(!ops.iter().any(|op| matches!(&op.change,
        Change::Row(row) if row.kind == RowKind::User && !row.open)));
    let gone = ops
        .iter()
        .find_map(|op| match &op.change {
            Change::Leave(row) if row.kind == RowKind::User => Some(row.fields.clone()),
            _ => None,
        })
        .unwrap();
    assert_eq!(gone, BTreeMap::from([("hidden".to_owned(), "true".to_owned())]));
}

const CLAIM: &str = r#"{"promptId":"p","claimed":{"harness":"claude-code","entrypoint":"cli","sessionId":" s1 ","appVersion":"9","pid":7,"selfReported":true},"checked":{"harness":"claude-code","peerPid":7}}"#;
const SENT_FROM: &str = r#"{"checked":{"harness":"claude-code"},"confirmed":true,"harness":"claude-code","label":"Claude Code","promptId":"p","sessionId":"s1"}"#;

#[test]
fn a_claim_before_its_prompt_is_held_and_one_after_patches_the_row_with_its_bodies() {
    // Kept in the queue first: the claim waits for the echo.
    let mut state = State::default();
    let ops = run(
        &mut state,
        &[
            mux(1, "queued", r#"{"text":"hello","promptId":"p"}"#),
            mux(2, "sender_claim", CLAIM),
            prompt(3, "p"),
        ],
    );
    assert_eq!(user_row(&ops, "p")["sentFrom"], SENT_FROM);
    assert!(ops.iter().all(|op| !matches!(op.change, Change::Patch(_))));
    // Started at once: the claim comes after the row settled, and patches it whole.
    let mut state = State::default();
    let said = r#"{"promptId":"p","turnId":"p","text":"hello","images":[{"id":"i"}]}"#;
    let ops =
        run_placed(&mut state, &[mux(1, "user_message", said), mux(2, "sender_claim", CLAIM)]);
    let settled = ops
        .iter()
        .find_map(|op| match &op.change {
            Change::Row(row) if row.kind == RowKind::User && !row.open => Some(row.clone()),
            _ => None,
        })
        .unwrap();
    let at = ops.iter().position(|op| matches!(op.change, Change::Patch(_))).unwrap();
    let Change::Patch(patch) = &ops[at].change else { unreachable!() };
    assert_eq!(patch.id, settled.id);
    assert_eq!(patch.rev, settled.rev + 1);
    let mut expected = settled.fields;
    expected.insert("sentFrom".into(), SENT_FROM.into());
    assert_eq!(patch.fields, expected);
    // Its bodies, read again from the prompt's line, just before the patch.
    assert_eq!(
        bodies(&ops[..at], patch.id)
            .into_iter()
            .filter(|(_, source)| matches!(source, BodySource::Raw { .. }))
            .collect::<Vec<_>>(),
        [
            (BodyField::Content, BodySource::Raw { place: 100, span: 1 }),
            (BodyField::Images, BodySource::Raw { place: 100, span: 1 }),
        ]
    );
    // A second claim of a prompt whose row it can no longer patch is counted.
    run(&mut state, &[mux(3, "sender_claim", CLAIM)]);
    assert_eq!(state.counters().unplaced_claims, 1);
}

#[test]
fn a_claim_reads_as_the_view_reads_it() {
    let read = |claim: &str| {
        user::sent_from(&serde_json::value::RawValue::from_string(claim.to_owned()).unwrap())
            .map(|(_, from)| from)
    };
    assert_eq!(
        read(
            r#"{"promptId":"p","claimed":{"harness":"claude-code","app":"Claude.app"},"checked":{"app":"Claude.app","signedBy":"x"}}"#
        )
        .as_deref(),
        Some(
            r#"{"checked":{"app":"Claude.app","signedBy":"x"},"confirmed":true,"harness":"claude-code","label":"Claude desktop","promptId":"p"}"#
        )
    );
    assert_eq!(
        read(r#"{"promptId":"p","claimed":{"harness":"claude-code","entrypoint":"sdk-ts"}}"#)
            .as_deref(),
        Some(
            r#"{"confirmed":false,"harness":"claude-code","label":"Claude Agent SDK","promptId":"p"}"#
        )
    );
    assert_eq!(
        read(r#"{"promptId":"p","claimed":{"harness":"codex"},"checked":{}}"#).as_deref(),
        Some(r#"{"confirmed":false,"harness":"codex","label":"Codex","promptId":"p"}"#)
    );
    // No harness, a control character, or a field past 128 units: no claim, or no field.
    assert_eq!(read(r#"{"promptId":"p","claimed":{}}"#), None);
    assert_eq!(read(r#"{"promptId":"p","claimed":{"harness":"a\u0007"}}"#), None);
    let long = "x".repeat(129);
    let claim = format!(r#"{{"promptId":"p","claimed":{{"harness":"pi","sessionId":"{long}"}}}}"#);
    assert_eq!(
        read(&claim).as_deref(),
        Some(r#"{"confirmed":false,"harness":"pi","label":"pi","promptId":"p"}"#)
    );
}

#[test]
fn a_turns_group_row_names_its_prompt_and_its_first_words() {
    let mut state = State::default();
    let text = format!("Line one\\nsecond \\\"quoted\\\" \\ud83d\\ude00 {}", "é".repeat(200));
    let said = format!(r#"{{"promptId":"p","turnId":"p","text":"{text}"}}"#);
    let ops = run(&mut state, &[mux(1, "user_message", &said)]);
    let fields = group(&ops);
    let id = ops
        .iter()
        .find_map(|op| match &op.change {
            Change::Row(row) if row.kind == RowKind::User => Some(row.id),
            _ => None,
        })
        .unwrap();
    assert_eq!(fields["prompt"], id.to_string());
    assert_eq!(fields["promptId"], "\"p\"");
    // The group row is the turn header: it carries the turn's start, its phase says running.
    assert!(fields["startMs"].parse::<u64>().is_ok(), "{fields:?}");
    let head: String = serde_json::from_str(&fields["head"]).unwrap();
    assert!(head.starts_with("Line one\nsecond \"quoted\" \u{1F600} é"), "{head:?}");
    assert!(head.len() <= user::HEAD_BYTES && head.len() > user::HEAD_BYTES - 2, "{}", head.len());
    // A prompt with no text names no head.
    let mut state = State::default();
    let ops = run(&mut state, &[mux(1, "user_message", r#"{"promptId":"p","turnId":"p"}"#)]);
    assert!(!group(&ops).contains_key("head"));
}

/// The user row of a `user_message` with `provenance` (and `extra` keys), its id `m`.
fn said_by(provenance: &str, extra: &str) -> (BTreeMap<String, String>, State) {
    let mut state = State::default();
    let said = format!(
        r#"{{"promptId":"m","turnId":"m","text":"hi","client":"acpmux-cli#1@lane-3"{extra},"_meta":{{"provenance":{provenance}}}}}"#
    );
    let row = user_row(&run(&mut state, &[mux(1, "user_message", &said)]), "m");
    (row, state)
}

#[test]
fn incoming_names_the_sender_the_record_proves() {
    // Another chat here, by its session: its short name, its harness.
    let (row, _) = said_by(
        r#"{"kind":"session_message","from":"acp:s1","fromName":"claude-sr2/coordinator","fromShortName":"coordinator","fromHarness":"claude","fromSessionId":"s1"}"#,
        "",
    );
    assert_eq!(
        row["incoming"],
        r#"{"kind":"message","sender":{"harness":"claude","name":"coordinator"}}"#
    );
    assert!(!row.contains_key("viaCli") && !row.contains_key("author"), "untyped: {row:?}");
    // A relayed sender: its whole address, from the relay's record the hub proved.
    let (row, _) = said_by(
        r#"{"kind":"agent_message","from":"relay:x","fromName":"gcp-agent-lane-2/lock-proof","fromRelay":{"by":"lane-gh","machine":"gcp-agent-lane-2","session":"lock-proof-routes"}}"#,
        "",
    );
    assert_eq!(
        row["incoming"],
        r#"{"kind":"message","sender":{"name":"gcp-agent-lane-2/lock-proof","relay":"gcp-agent-lane-2/lock-proof-routes"}}"#
    );
    // A sender the hub could not verify: its record says so, and an older name's suffix goes.
    let (row, _) = said_by(
        r#"{"kind":"agent_message","from":"cli","fromName":"lane-7 (self-declared, unauthenticated)","sender":{"verification":"declared","harness":"codex"}}"#,
        "",
    );
    assert_eq!(
        row["incoming"],
        r#"{"kind":"message","sender":{"harness":"codex","name":"lane-7","unverified":true}}"#
    );
    // No proof at all: unverified, named by the program the hub saw run the send, if any.
    let (row, _) = said_by(r#"{"kind":"unverified","program":{"name":" helper.sh "}}"#, "");
    assert_eq!(
        row["incoming"],
        r#"{"kind":"message","sender":{"name":"helper.sh","unverified":true}}"#
    );
    // A sender that only named itself: its name is in its text, the page's to read.
    let (row, _) = said_by(r#"{"kind":"agent_message","from":"fromAgent"}"#, "");
    assert_eq!(row["incoming"], r#"{"kind":"message","sender":{"unverified":true}}"#);
    // The hub's own: its message, its inbox notice, its bookkeeping.
    let (row, _) = said_by(r#"{"kind":"turn_cap"}"#, "");
    assert_eq!(row["incoming"], r#"{"kind":"message","sender":{"name":"acpmux"}}"#);
    let (row, _) = said_by(r#"{"kind":"inbox_notice"}"#, "");
    assert_eq!(row["incoming"], r#"{"kind":"inbox"}"#);
    let (row, _) = said_by(r#"{"kind":"auto_resume"}"#, "");
    assert_eq!(row["incoming"], r#"{"kind":"hidden"}"#);
}

#[test]
fn a_record_that_proves_no_sender_writes_no_incoming() {
    // No provenance: the person's own as far as the record says; the page reads its text.
    let mut state = State::default();
    let said =
        r#"{"promptId":"m","turnId":"m","text":"[lane-7] merged","client":"acpmux-cli#1@lane-3"}"#;
    let row = user_row(&run(&mut state, &[mux(1, "user_message", said)]), "m");
    assert!(!row.contains_key("incoming"), "{row:?}");
    assert_eq!(row["viaCli"], "\"lane-3\"");
    // A person's prompt: typed, with its author.
    let (row, _) =
        said_by(r#"{"kind":"person_message","from":"tailnet:ana","fromName":"Ana"}"#, "");
    assert!(!row.contains_key("incoming"));
    assert_eq!(row["author"], r#"{"id":"tailnet:ana","name":"Ana"}"#);
}

#[test]
fn each_sender_cap_cuts_and_counts() {
    let long = "n".repeat(300);
    let harness = "h".repeat(80);
    let (row, state) = said_by(
        &format!(
            r#"{{"kind":"session_message","from":"acp:s","fromName":"{long}","fromHarness":"{harness}","sender":{{"verification":"verified","relay":{{"machine":"m","session":"{long}"}}}}}}"#
        ),
        "",
    );
    let incoming: serde_json::Value = serde_json::from_str(&row["incoming"]).unwrap();
    assert_eq!(incoming["sender"]["name"].as_str().unwrap().len(), 256);
    assert_eq!(incoming["sender"]["harness"].as_str().unwrap().len(), 64);
    assert_eq!(incoming["sender"]["relay"].as_str().unwrap().len(), 256);
    assert_eq!(state.counters().cut_fields, 3);
    // A claim names no row that is the hub's notice of the inbox.
    let mut state = State::default();
    let said = r#"{"promptId":"p","turnId":"p","text":"x","_meta":{"provenance":{"kind":"inbox_notice"}}}"#;
    let ops = run(&mut state, &[mux(1, "user_message", said), mux(2, "sender_claim", CLAIM)]);
    assert!(!user_row(&ops, "p").contains_key("sentFrom"));
    assert!(ops.iter().all(|op| !matches!(op.change, Change::Patch(_))));
}

#[test]
fn every_held_state_full_at_once_fits_the_translators_segment() {
    // A turn ends `continued` under a prompt sent now, and that notice is held whole.
    let mut state = State::default();
    let mut lines = sent_now("cancelled");
    lines[3] = mux(
        4,
        "turn_result",
        &format!(r#"{{"turnId":"p","status":"cancelled","errorText":"{}"}}"#, "e".repeat(5000)),
    );
    let long = |c: &str, n: usize| c.repeat(n);
    // The settled prompt a claim may still patch, at its caps.
    lines[0] = mux(
        1,
        "user_message",
        &format!(
            r#"{{"promptId":"p","turnId":"p","text":"q","_meta":{{"provenance":{{"kind":"session_message","fromShortName":"{}","fromHarness":"{}"}}}}}}"#,
            long("n", 300),
            long("h", 80)
        ),
    );
    let mut seq = 10;
    let mut next = || {
        seq += 1;
        seq
    };
    // Steers waiting, each at its caps, past the 32 rows and 12 KB they may hold.
    for n in 0..40 {
        let said = format!(
            r#"{{"promptId":"s{n:02}{}","turnId":"p","text":"also","steer":true,"_meta":{{"provenance":{{"kind":"session_message","fromShortName":"{}","fromHarness":"{}"}}}}}}"#,
            long("i", 253),
            long("n", 300),
            long("h", 80)
        );
        lines.push(mux(next(), "user_message", &said));
    }
    // Asks open, each at its caps, past the 8 KB of fields they may hold (32 small ones fit).
    for n in 0..40 {
        let ask = format!(
            r#"{{"permissionId":"a{n:02}{}","groupId":"{}","turnId":"{}","request":{{"toolCall":{{"title":"{}"}},"options":[]}}}}"#,
            long("i", 253),
            long("g", 256),
            long("t", 256),
            long("x", 200)
        );
        lines.push(mux(next(), "permission_request", &ask));
    }
    // Claims held for prompts not yet echoed, each at its caps, past the 16 and 4 KB they may hold.
    for n in 0..20 {
        let claim = format!(
            r#"{{"promptId":"c{n}","claimed":{{"harness":"claude-code","sessionId":"{}","hostSessionId":"{}"}},"checked":{{"harness":"claude-code"}}}}"#,
            long("中", 128),
            long("中", 128)
        );
        lines.push(mux(next(), "sender_claim", &claim));
    }
    run(&mut state, &lines);
    // The cards at theirs, after every other line (decisions 253, 254).
    cards_tests::run(&mut state, &cards_tests::full_card_lines(1_000_000));
    assert!(!state.cards.is_empty());
    assert!(state.card_bytes() <= cards::MAX_CARD_BYTES, "{}", state.card_bytes());
    assert_eq!(state.line_failures(), (0, 0), "every line at its caps is read");
    assert!(state.continued.is_some(), "the held notice");
    assert!(state.claimable.is_some(), "the row a claim may patch");
    let asked: usize = state.asks.values().map(|ask| fields_bytes(&ask.row)).sum();
    assert!(!state.asks.is_empty() && state.asks.len() <= 32 && asked <= 8 * 1024, "{asked}");
    assert!(!state.prompts.is_empty() && state.held_steer_bytes() <= MAX_HELD_STEER_BYTES);
    let claimed: usize = state.claims.iter().map(|(_, from)| from.len()).sum();
    assert!(!state.claims.is_empty() && claimed <= MAX_HELD_CLAIM_BYTES, "{claimed}");
    let counters = state.counters();
    assert!(counters.forced_asks > 0 && counters.forced_steers > 0 && counters.unplaced_claims > 0);
    let len = |name: &str, bytes: usize| println!("part {name}: {bytes} bytes");
    len("whole", checkpoint::encoded_len(&(VERSION, &state)));
    len("prompts", checkpoint::encoded_len(&state.prompts));
    len("asks", checkpoint::encoded_len(&state.asks));
    len("claims", checkpoint::encoded_len(&state.claims));
    len("continued", checkpoint::encoded_len(&state.continued));
    len("claimable", checkpoint::encoded_len(&state.claimable));
    len("cards", checkpoint::encoded_len(&state.cards));
    for kind in cards::Card::kinds(&state.cards) {
        len(&kind.0, kind.1);
    }
    let saved = state.checkpoint().expect("every held state at its bound fits");
    println!(
        "full held state: {} of {MAX_TRANSLATOR_BYTES} bytes ({} cards, {} bytes of them); {} left for the live turn",
        saved.translator.len(),
        state.cards.len(),
        state.card_bytes(),
        MAX_TRANSLATOR_BYTES - saved.translator.len()
    );
    // And comes back whole.
    let restored = saved.restore().unwrap();
    assert_eq!(restored.asks.len(), state.asks.len());
    assert!(restored.continued.is_some());
    assert_eq!(restored.cards, state.cards);
}

#[test]
fn the_turn_header_starts_at_the_turns_start_record_not_its_prompt() {
    let mut state = State::default();
    let said = r#"{"seq":1,"at":1000,"dir":"mux","kind":"user_message","msg":{"promptId":"p","turnId":"t","text":"hi"}}"#;
    let ops = run(&mut state, &[said.into()]);
    assert_eq!(group(&ops)["startMs"], "1000");
    let started = r#"{"seq":2,"at":2500,"dir":"mux","kind":"turn_started","msg":{"turnId":"t","promptId":"p"}}"#;
    let ops = run(&mut state, &[started.into()]);
    assert_eq!(group(&ops)["startMs"], "2500");
    // Another turn's start record leaves this turn's clock alone.
    let other = r#"{"seq":3,"at":4000,"dir":"mux","kind":"turn_started","msg":{"turnId":"u"}}"#;
    let ops = run(&mut state, &[other.into()]);
    assert!(
        !ops.iter().any(|op| matches!(&op.change, Change::Row(row) if row.kind == RowKind::Group))
    );
}
