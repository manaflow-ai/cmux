//! The kind table, the counter of kinds in none of it, and the turn-end notice (decision 231).
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects,
    reason = "deterministic inputs and assertions"
)]
use super::*;
use kinds::{Draw, MUX, UPDATES};

fn mux(seq: u64, kind: &str, msg: &str) -> String {
    format!(r#"{{"seq":{seq},"at":1000,"dir":"mux","kind":"{kind}","msg":{msg}}}"#)
}
fn update(seq: u64, payload: &str) -> String {
    format!(
        r#"{{"seq":{seq},"at":1000,"dir":"in","kind":"session/update","msg":{{"method":"session/update","params":{{"update":{payload}}}}}}}"#
    )
}
/// Every op of `lines`, translated in order into one state.
fn run(state: &mut State, harness: Harness, lines: &[String]) -> Vec<Op> {
    let mut ops = Vec::new();
    for line in lines {
        ops.extend(translate(state, harness, 0, 1, line.as_bytes()).unwrap());
    }
    ops
}
/// The settled turn-end notice's fields, as the row op last wrote them.
fn turn_end(ops: &[Op]) -> BTreeMap<String, String> {
    let ends: Vec<_> = ops
        .iter()
        .filter_map(|op| match &op.change {
            Change::Row(row)
                if !row.open
                    && row.fields.get("notice").map(String::as_str) == Some("\"turn_result\"") =>
            {
                Some(row.fields.clone())
            }
            _ => None,
        })
        .collect();
    assert_eq!(ends.len(), 1, "one turn-end notice: {ends:?}");
    ends.into_iter().next().unwrap()
}
fn fields(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}
fn prompt(seq: u64, id: &str) -> String {
    mux(seq, "user_message", &format!(r#"{{"promptId":"{id}","turnId":"{id}","text":"q"}}"#))
}

#[test]
fn the_tables_are_sorted_with_one_line_a_kind() {
    for table in [MUX, UPDATES] {
        for pair in table.windows(2) {
            assert!(pair[0].name < pair[1].name, "{} before {}", pair[0].name, pair[1].name);
        }
        for kind in table {
            match kind.draw {
                Draw::Row(drawn) => assert!(drawn.patch.is_empty() || !drawn.notice.is_empty()),
                Draw::Code(why) | Draw::Not(why) => assert!(!why.is_empty(), "{}", kind.name),
                Draw::PageState => {}
            }
        }
    }
    assert!(!kinds::PROTOCOL.is_empty());
    // Decision 234: the kinds whose every record carries its whole state, which the page reads.
    let mut page: Vec<_> = kinds::page_state().collect();
    page.sort_unstable();
    assert_eq!(
        page,
        [
            "available_commands_update",
            "bookmarks",
            "config_option_update",
            "current_mode_update",
            "race",
            "session_info_update",
            "status",
            "subsession",
            "usage_update",
        ]
    );
    // Decision 241: a kind split by its event has a line for the kind too, and each event's says why.
    for (kind, event, draw) in kinds::EVENTS {
        assert!(kinds::find(MUX, kind).is_some(), "{kind}");
        assert!(!event.is_empty());
        assert!(!matches!(draw, Draw::Not(why) if why.is_empty()));
    }
}

#[test]
fn every_kind_in_the_tables_and_the_fixtures_counts_none() {
    let mut state = State::default();
    let mut lines: Vec<String> = Vec::new();
    for (n, kind) in MUX.iter().enumerate() {
        lines.push(mux(n as u64 + 1, kind.name, "{}"));
    }
    let base = MUX.len() as u64;
    for (n, kind) in UPDATES.iter().enumerate() {
        lines.push(update(base + n as u64 + 1, &format!(r#"{{"sessionUpdate":"{}"}}"#, kind.name)));
    }
    run(&mut state, Harness::V1, &lines);
    assert_eq!(state.counters().unknown_kinds, BTreeMap::new());
    for fixture in [
        include_str!("fixtures/seed-turn.ndjson"),
        include_str!("fixtures/r1-reply-1.ndjson"),
        include_str!("fixtures/r1-reply-2.ndjson"),
    ] {
        let mut state = State::default();
        let lines: Vec<String> = fixture.lines().map(str::to_owned).collect();
        run(&mut state, Harness::V1, &lines);
        assert_eq!(state.counters().unknown_kinds, BTreeMap::new());
        assert_eq!(state.counters().line_errors, 0);
    }
}

#[test]
fn a_kind_in_no_table_is_counted_by_name_then_as_other() {
    let mut state = State::default();
    let mut lines = vec![mux(1, "brand_new", "{}"), mux(2, "brand_new", "{}")];
    lines.push(update(3, r#"{"sessionUpdate":"brand_new_update"}"#));
    for n in 0..40u64 {
        lines.push(mux(10 + n, &format!("new_{n:02}"), "{}"));
    }
    lines.push(mux(60, "brand_new", "{}"));
    run(&mut state, Harness::V1, &lines);
    let counted = state.counters().unknown_kinds;
    assert_eq!(counted["brand_new"], 3);
    assert_eq!(counted["brand_new_update"], 1);
    assert_eq!(counted.len(), MAX_UNKNOWN_KINDS + 1, "32 names, then other: {counted:?}");
    assert_eq!(counted[UNKNOWN_OTHER], 40 - 30);
    assert_eq!(counted.values().sum::<u64>(), 44);
}

#[test]
fn each_result_field_goes_into_the_turn_end_notice() {
    let mut state = State::default();
    let result = r#"{"turnId":"p~resume-2","promptId":"p~resume-2","status":"failed","errorText":"model unreachable","error":"ignored","errorCode":"overloaded","cancelForced":true,"inputTokens":40,"outputTokens":7,"cacheReadTokens":10,"cacheWriteTokens":2,"contextTokens":30,"modelCalls":3,"checkpointId":"c1","endCheckpointId":"c2","checkpointError":"too large"}"#;
    let ops =
        run(&mut state, Harness::V1, &[prompt(1, "p~resume-2"), mux(7, "turn_result", result)]);
    // An unmarked record from a model that is not a Claude counted its cache in its input.
    assert_eq!(
        turn_end(&ops),
        fields(&[
            ("notice", "\"turn_result\""),
            ("forkable", "true"),
            ("seq", "7"),
            ("status", "\"failed\""),
            ("error", "\"model unreachable\""),
            ("errorCode", "\"overloaded\""),
            ("stopForced", "true"),
            (
                "tokens",
                r#"{"output":7,"input":28,"cacheRead":10,"cacheWrite":2,"context":30,"calls":3}"#
            ),
            ("checkpoint", r#"{"from":"c1","to":"c2","reason":"too large"}"#),
            ("retry", "2"),
        ])
    );
    assert!(!state.in_turn());
}

#[test]
fn a_result_with_none_of_the_optional_fields_writes_none() {
    let mut state = State::default();
    let ops =
        run(&mut state, Harness::V1, &[prompt(1, "p"), mux(2, "turn_result", r#"{"turnId":"p"}"#)]);
    assert_eq!(
        turn_end(&ops),
        fields(&[("notice", "\"turn_result\""), ("forkable", "true"), ("seq", "2")])
    );
    // Zero tokens, a false flag, an empty code, a code that is not a string, `error` on a turn
    // that did not fail, and checkpoints without the starting one's key: all absent.
    let mut state = State::default();
    let quiet = r#"{"turnId":"p","status":"completed","outputTokens":0,"inputTokens":0,"cancelForced":false,"errorCode":"","code":-32603,"error":"late","endCheckpointId":"c2"}"#;
    let ops = run(&mut state, Harness::V1, &[prompt(1, "p"), mux(2, "turn_result", quiet)]);
    assert_eq!(
        turn_end(&ops),
        fields(&[
            ("notice", "\"turn_result\""),
            ("forkable", "true"),
            ("seq", "2"),
            ("status", "\"completed\""),
        ])
    );
}

#[test]
fn a_failed_start_names_its_error_and_a_marked_input_is_fresh() {
    let mut state = State::default();
    let failed = r#"{"turnId":"p","status":"failed","error":"agent did not start","checkpointId":null,"inputTokens":40,"outputTokens":7,"cacheReadTokens":10,"inputExcludesCache":true}"#;
    let ops = run(&mut state, Harness::V1, &[prompt(1, "p"), mux(2, "turn_result", failed)]);
    let end = turn_end(&ops);
    assert_eq!(end["error"], "\"agent did not start\"");
    assert_eq!(end["checkpoint"], r#"{"from":null}"#);
    assert_eq!(end["tokens"], r#"{"output":7,"input":40,"cacheRead":10,"cacheWrite":0}"#);
    let mut state = State::default();
    let claude = r#"{"turnId":"p","inputTokens":40,"outputTokens":7,"cacheReadTokens":10,"model":"claude-opus-5-5"}"#;
    let ops = run(&mut state, Harness::V1, &[prompt(1, "p"), mux(2, "turn_result", claude)]);
    assert_eq!(
        turn_end(&ops)["tokens"],
        r#"{"output":7,"input":40,"cacheRead":10,"cacheWrite":0}"#
    );
}

#[test]
fn a_long_error_is_cut_and_counted() {
    let mut state = State::default();
    let long = "é".repeat(4000);
    let result = format!(r#"{{"turnId":"p","status":"failed","errorText":"{long}"}}"#);
    let ops = run(&mut state, Harness::V1, &[prompt(1, "p"), mux(2, "turn_result", &result)]);
    let error: String = serde_json::from_str(&turn_end(&ops)["error"]).unwrap();
    assert_eq!(error.len(), 4096);
    assert!(state.counters().cut_fields > 0);
}

#[test]
fn a_claude_turn_ends_with_a_notice_of_its_tokens() {
    let user = r#"{"type":"user","uuid":"u1","message":{"content":"Question"}}"#;
    // A call's lines repeat its usage; the last one names its whole output.
    let call = |id: &str, output: u64, stop: &str| {
        format!(
            r#"{{"type":"assistant","message":{{"id":"{id}","content":[{{"type":"text","text":"a"}}],"stop_reason":{stop},"usage":{{"input_tokens":5,"output_tokens":{output},"cache_read_input_tokens":100,"cache_creation_input_tokens":2}}}}}}"#
        )
    };
    let lines = [
        user.to_owned(),
        call("m1", 1, "null"),
        call("m1", 4, "\"tool_use\""),
        call("m2", 6, "\"end_turn\""),
        r#"{"type":"result","subtype":"success"}"#.to_owned(),
    ];
    let mut state = State::default();
    let ops = run(&mut state, Harness::Claude, &lines);
    // No v1 seq: not forkable, and no seq. The context is the last call's.
    assert_eq!(
        turn_end(&ops),
        fields(&[
            ("notice", "\"turn_result\""),
            ("status", "\"completed\""),
            (
                "tokens",
                r#"{"output":10,"input":10,"cacheRead":200,"cacheWrite":4,"context":107,"calls":2}"#
            ),
        ])
    );
    let mut state = State::default();
    let ops = run(
        &mut state,
        Harness::Claude,
        &[
            user.to_owned(),
            r#"{"type":"result","subtype":"error_during_execution","is_error":true}"#.to_owned(),
        ],
    );
    assert_eq!(turn_end(&ops), fields(&[("notice", "\"turn_result\""), ("status", "\"failed\"")]));
}

#[test]
fn a_claude_result_names_its_error_by_is_error_alone() {
    let user = r#"{"type":"user","uuid":"u1","message":{"content":"Question"}}"#;
    let mut state = State::default();
    let ops = run(
        &mut state,
        Harness::Claude,
        &[user.to_owned(), r#"{"type":"result","subtype":"success","is_error":true}"#.to_owned()],
    );
    assert_eq!(turn_end(&ops)["status"], "\"failed\"");
}

#[test]
fn an_interrupted_claude_turn_leaves_no_tokens_to_the_next() {
    let user = r#"{"type":"user","uuid":"u1","message":{"content":"Question"}}"#;
    let call = |id: &str, output: u64, stop: &str| {
        format!(
            r#"{{"type":"assistant","message":{{"id":"{id}","content":[{{"type":"text","text":"a"}}],"stop_reason":{stop},"usage":{{"input_tokens":5,"output_tokens":{output},"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}}}}"#
        )
    };
    let mut state = State::default();
    let ops = run(
        &mut state,
        Harness::Claude,
        &[
            user.to_owned(),
            call("m1", 9, "null"),
            r#"{"type":"user","uuid":"u2","message":{"content":"Another"}}"#.to_owned(),
            call("m2", 3, "\"end_turn\""),
        ],
    );
    assert_eq!(
        turn_end(&ops)["tokens"],
        r#"{"output":3,"input":5,"cacheRead":0,"cacheWrite":0,"context":5,"calls":1}"#
    );
    // A usage that is no object reads as none, and the line still translates.
    let mut state = State::default();
    let null_usage = r#"{"type":"assistant","message":{"id":"m","content":[{"type":"text","text":"a"}],"stop_reason":"end_turn","usage":null}}"#;
    let ops = run(&mut state, Harness::Claude, &[user.to_owned(), null_usage.to_owned()]);
    assert!(!turn_end(&ops).contains_key("tokens"));
    assert_eq!(state.counters().line_errors, 0);
}
