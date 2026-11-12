#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects,
    reason = "assertions and deterministic generated test inputs"
)]
use super::*;
use crate::row::Placement;

pub(super) const SEED: &str = include_str!("fixtures/seed-turn.ndjson");
fn run(state: &mut State, harness: Harness, lines: &[String]) -> Vec<Op> {
    lines.iter().flat_map(|s| translate(state, harness, s.as_bytes()).unwrap()).collect()
}
#[derive(Default)]
struct Mirror {
    rows: BTreeMap<u64, OwnedRow>,
    last_id: u64,
}
impl Mirror {
    fn apply(&mut self, op: &Op) {
        match &op.change {
            Change::Row(row) => {
                if let Some(old) = self.rows.get(&row.id) {
                    assert!(old.open, "no settled row changes");
                    assert_eq!(
                        (old.id, old.at, old.turn, old.group),
                        (row.id, row.at, row.turn, row.group)
                    );
                } else {
                    assert_eq!(row.id, self.last_id + 1);
                    self.last_id = row.id;
                }
                self.rows.insert(row.id, row.clone());
            }
            Change::Update { id, fields, text } => {
                let row = self.rows.get_mut(id).unwrap();
                assert!(row.open);
                row.fields.extend(fields.clone());
                if let Some(text) = text {
                    row.text.clone_from(text);
                }
            }
            Change::Text { id, text } => {
                let row = self.rows.get_mut(id).unwrap();
                assert!(row.open);
                row.text.push_str(text);
            }
        }
    }
}
#[test]
fn seed_fold_turn_has_the_same_words_tools_and_reply_order() {
    let mut state = State::default();
    let mut mirror = Mirror::default();
    for line in SEED.split_inclusive('\n') {
        for op in translate(&mut state, Harness::V1, line.as_bytes()).unwrap() {
            assert_eq!(op.raw, RawRange { offset: 0, length: line.len() });
            mirror.apply(&op);
        }
    }
    let texts: Vec<_> = mirror.rows.values().filter(|r| r.kind == RowKind::Text).collect();
    assert_eq!(
        texts.iter().map(|r| r.text.as_str()).collect::<Vec<_>>(),
        ["Let me look.", "Done."]
    );
    assert!(texts.iter().all(|r| r.turn == Some(1) && r.group.is_none() && !r.open));
    let tool = mirror.rows.values().find(|r| r.kind == RowKind::Tool).unwrap();
    assert_eq!(tool.text, "fn a() {}");
    assert_eq!(tool.fields["tool"], "\"Read\"");
    assert_eq!(tool.group, Some(3));
    assert!(!tool.open);
    assert_eq!(state.open_rows().count(), 0);
    for row in mirror.rows.values() {
        let body = row.body();
        let mut bytes = Vec::new();
        assert_eq!(row.as_row(&body).encode(None, &mut bytes), Ok(Placement::Inline));
    }
}
fn update(seq: u64, payload: &str) -> String {
    format!(
        r#"{{"seq":{seq},"at":10000,"dir":"in","kind":"session/update","msg":{{"method":"session/update","params":{{"update":{payload}}}}}}}"#
    )
}
fn chunk(seq: u64, text: &str) -> String {
    let mut s = String::new();
    quoted(&mut s, text);
    update(
        seq,
        &format!(
            r#"{{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{{"type":"text","text":{s}}}}}"#
        ),
    )
}
fn mux(seq: u64, kind: &str, payload: &str) -> String {
    format!(r#"{{"seq":{seq},"at":10000,"dir":"mux","kind":"{kind}","msg":{payload}}}"#)
}
fn next(seed: &mut u64) -> u64 {
    *seed ^= *seed << 13;
    *seed ^= *seed >> 7;
    *seed ^= *seed << 17;
    *seed
}
#[test]
fn th1_th2_th4_th5_ten_thousand_random_splits_replay_and_interleavings() {
    let mut rng = 0xc0ffee12345678;
    for case in 0..10_000 {
        let mut lines = vec![mux(1, "user_message", r#"{"text":"question","turnId":"person"}"#)];
        let n = next(&mut rng) % 25 + 5;
        let final_at = 2 + next(&mut rng) % (n - 2);
        for seq in 2..n {
            if seq == final_at {
                lines.push(chunk(seq, "FINAL"));
                continue;
            }
            let line = match next(&mut rng) % 10 {
                0 => chunk(seq, "answer "),
                1 => update(
                    seq,
                    r#"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"think"}}"#,
                ),
                2 => update(
                    seq,
                    r#"{"sessionUpdate":"tool_call","toolCallId":"t","status":"running"}"#,
                ),
                3 => update(
                    seq,
                    r#"{"sessionUpdate":"tool_call_update","toolCallId":"t","status":"completed","content":{"type":"text","text":"output"}}"#,
                ),
                4 => mux(seq, "user_message", r#"{"text":"steer","steer":true}"#),
                5 => mux(seq, "host_notice", r#"{"text":"background finished"}"#),
                6 => mux(seq, "turn_result", r#"{"turnId":"notice-turn","status":"completed"}"#),
                7 => update(seq, r#"{"sessionUpdate":"usage_update","used":1}"#),
                8 => mux(
                    seq,
                    "user_message",
                    r#"{"text":"inbox","turnId":"notice-turn","_meta":{"provenance":{"kind":"inbox_notice"}}}"#,
                ),
                _ => format!(
                    r#"{{"seq":{seq},"at":10000,"dir":"in","kind":"session/update","msg":{{"method":"session/update","params":{{"_meta":{{"acpmux":{{"subagent":"child"}}}},"update":{{"sessionUpdate":"agent_message_chunk","content":{{"type":"text","text":"child"}}}}}}}}}}"#
                ),
            };
            lines.push(line);
        }
        lines.push(mux(n + 1, "turn_result", r#"{"turnId":"person","status":"completed"}"#));
        let mut whole = State::default();
        let ops = run(&mut whole, Harness::V1, &lines);
        let cut = next(&mut rng) as usize % (lines.len() + 1);
        let mut part = State::default();
        let mut split = run(&mut part, Harness::V1, &lines[..cut]);
        let saved = part.checkpoint().unwrap();
        let mut replay = State::restore(&saved).unwrap();
        let tail = run(&mut part, Harness::V1, &lines[cut..]);
        assert_eq!(tail, run(&mut replay, Harness::V1, &lines[cut..]), "kill replay {case}");
        split.extend(tail);
        assert_eq!(split, ops, "split {case}");
        assert_eq!(part, whole);
        assert_eq!(replay, whole);
        assert!(whole.open_rows().all(|r| r.kind == RowKind::Tool));
        let mut mirror = Mirror::default();
        for op in &ops {
            mirror.apply(op);
        }
        let final_row = mirror.rows.values().find(|r| r.text.contains("FINAL")).unwrap();
        assert_eq!(final_row.turn, Some(1));
        assert_eq!(final_row.group, None);
        assert!(!final_row.open);
        assert!(!mirror.rows.values().any(|r| r.text.contains("child")));
        assert!(run(&mut part, Harness::V1, &lines).is_empty(), "duplicate page is no-op");
    }
}
#[test]
fn th3_delta_contains_only_its_own_text() {
    let mut state = State::default();
    translate(&mut state, Harness::V1, chunk(1, &"x".repeat(8000)).as_bytes()).unwrap();
    let ops = translate(&mut state, Harness::V1, chunk(2, "🙂").as_bytes()).unwrap();
    assert_eq!(ops.len(), 1);
    assert_eq!(ops[0].change, Change::Text { id: 1, text: "🙂".into() });
}
#[test]
fn claude_transcript_tools_not_prompts_and_final_outside_group() {
    let lines = [
        r#"{"type":"user","timestamp":"2026-11-12T00:00:00Z","uuid":"p","message":{"content":"Question"}}"#,
        r#"{"type":"assistant","message":{"id":"m1","content":[{"type":"thinking","thinking":"think"},{"type":"tool_use","id":"t","name":"Read","input":{"file":"a"}}],"stop_reason":"tool_use"}}"#,
        r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"output"},{"type":"text","text":"not a prompt"}]}}"#,
        r#"{"type":"user","origin":{"kind":"task-notification"},"message":{"content":"Background done"}}"#,
        r#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"child"}]}}"#,
        r#"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"Final reply"}],"stop_reason":"end_turn"}}"#,
    ].map(str::to_owned);
    let mut state = State::default();
    let ops = run(&mut state, Harness::Claude, &lines);
    let mut mirror = Mirror::default();
    for op in &ops {
        mirror.apply(op);
    }
    assert_eq!(mirror.rows.values().filter(|r| r.kind == RowKind::User).count(), 1);
    let final_row = mirror.rows.values().find(|r| r.text == "Final reply").unwrap();
    assert_eq!((final_row.turn, final_row.group, final_row.at), (Some(1), None, 1794441600));
    for cut in 0..=lines.len() {
        let mut s = State::default();
        let mut split = run(&mut s, Harness::Claude, &lines[..cut]);
        s = State::restore(&s.checkpoint().unwrap()).unwrap();
        split.extend(run(&mut s, Harness::Claude, &lines[cut..]));
        assert_eq!(split, ops);
        assert_eq!(s, state);
    }
}
#[test]
fn malformed_input_and_checkpoints_are_named_errors() {
    let mut state = State::default();
    for bad in ["{", "{} {}", r#"{"seq":1,}"#, "[1,]", "1 e2", "{\"s\":\"\n\"}"] {
        assert!(translate(&mut state, Harness::V1, bad.as_bytes()).is_err(), "{bad}");
        assert_eq!(state, State::default());
    }
    let saved = state.checkpoint().unwrap();
    for end in 0..saved.len() {
        assert!(State::restore(&saved[..end]).is_err());
    }
    let mut extra = saved.clone();
    extra.push(0);
    assert!(State::restore(&extra).is_err());
}
#[test]
fn json_fields_skip_cold_values_and_decode_escapes() {
    let json = json::Json::parse(
        br#" {"cold":{"x":[1,2,{"text":"ignore"}]}, "te\u0078t":"\ud83d\ude42\n\"\\"} "#,
    )
    .unwrap();
    assert_eq!(json.text("text").as_deref(), Some("🙂\n\"\\"));
    assert_eq!(json.get("cold").unwrap().compact(), r#"{"x":[1,2,{"text":"ignore"}]}"#);
}

#[test]
fn a_final_chunk_after_turn_result_keeps_the_person_prompt() {
    let mut s = State::default();
    let lines = [
        mux(1, "user_message", r#"{"text":"question","turnId":"person"}"#),
        mux(2, "turn_result", r#"{"turnId":"person"}"#),
        mux(3, "host_notice", r#"{"text":"background finished"}"#),
        chunk(4, "FINAL"),
    ];
    let mut mirror = Mirror::default();
    for op in run(&mut s, Harness::V1, &lines) {
        mirror.apply(&op);
    }
    let row = mirror.rows.values().find(|r| r.text == "FINAL").unwrap();
    assert_eq!(row.turn, Some(1));
    assert_eq!(row.group, None);
}

#[test]
fn invalid_surrogate_never_silently_drops_a_reply() {
    let mut state = State::default();
    let line = update(
        1,
        r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\ud800"}}"#,
    );
    assert_eq!(translate(&mut state, Harness::V1, line.as_bytes()), Err(Error::InvalidJson));
    assert_eq!(state, State::default());
}

#[test]
fn terminal_delta_never_copies_the_earlier_output() {
    let mut s = State::default();
    let big = "x".repeat(8000);
    let first = update(
        1,
        &format!(
            r#"{{"sessionUpdate":"tool_call","toolCallId":"t","content":{{"type":"text","text":"{big}"}}}}"#
        ),
    );
    translate(&mut s, Harness::V1, first.as_bytes()).unwrap();
    let delta = update(
        2,
        r#"{"sessionUpdate":"tool_call_update","toolCallId":"t","_meta":{"terminal_output":{"data":"new"}}}"#,
    );
    let ops = translate(&mut s, Harness::V1, delta.as_bytes()).unwrap();
    assert_eq!(ops.len(), 1);
    assert_eq!(ops[0].change, Change::Text { id: 2, text: "new".into() });
}

#[test]
fn claude_string_content_is_a_visible_reply_too() {
    let mut s = State::default();
    let line =
        br#"{"type":"assistant","message":{"content":"Final reply","stop_reason":"end_turn"}}"#;
    let ops = translate(&mut s, Harness::Claude, line).unwrap();
    assert!(ops.iter().any(|op|matches!(&op.change,Change::Row(r) if r.text=="Final reply" && !r.open && r.group.is_none())));
}

#[test]
fn background_tool_result_keeps_its_original_row_after_the_turn_ends() {
    let mut s = State::default();
    let mut mirror = Mirror::default();
    let lines = [
        mux(1, "user_message", r#"{"text":"question","turnId":"person"}"#),
        update(2, r#"{"sessionUpdate":"tool_call","toolCallId":"bg","status":"running"}"#),
        mux(3, "turn_result", r#"{"turnId":"person"}"#),
        mux(4, "user_message", r#"{"text":"next","turnId":"next"}"#),
        update(
            5,
            r#"{"sessionUpdate":"tool_call_update","toolCallId":"bg","status":"completed","content":{"type":"text","text":"result"}}"#,
        ),
    ];
    for op in run(&mut s, Harness::V1, &lines) {
        mirror.apply(&op);
    }
    let tools: Vec<_> = mirror.rows.values().filter(|r| r.kind == RowKind::Tool).collect();
    assert_eq!(tools.len(), 1);
    assert_eq!(tools[0].turn, Some(1));
    assert_eq!(tools[0].text, "result");
    assert!(!tools[0].open);
}
