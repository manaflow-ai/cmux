#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects,
    reason = "deterministic generated inputs and assertions"
)]
use super::*;
const SEED: &str = include_str!("fixtures/seed-turn.ndjson");
const ANSWER: &str = "Sorry, that's frustrating. I did answer, but the chat drew the answer above your question, so it looked like I ignored you.\n\nMy answer was **no**, it shouldn't say cmux.";
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Mirror {
    rows: BTreeMap<u64, OwnedRow>,
    text: BTreeMap<u64, String>,
    raw: BTreeMap<(u64, String), String>,
}
impl Mirror {
    fn apply(&mut self, op: &Op, bytes: &[u8]) {
        assert!(op.raw.offset + op.raw.length <= bytes.len());
        match &op.change {
            Change::Row(row) => {
                if let Some(old) = self.rows.get(&row.id) {
                    assert!(old.open, "settled row {} changed", row.id);
                    assert_eq!(
                        (old.id, old.rev, old.at, old.group),
                        (row.id, row.rev, row.at, row.group)
                    );
                    if old.kind != RowKind::User {
                        assert_eq!(old.turn, row.turn);
                    }
                } else {
                    assert_eq!(row.id, self.rows.len() as u64 + 1);
                }
                if row.fields.get("hidden").is_some_and(|v| v == "true") {
                    self.text.remove(&row.id);
                }
                let mut merged = row.clone();
                if let Some(old) = self
                    .rows
                    .get(&row.id)
                    .filter(|_| !row.fields.get("hidden").is_some_and(|v| v == "true"))
                {
                    let fields = std::mem::take(&mut merged.fields);
                    merged.fields.clone_from(&old.fields);
                    merged.fields.extend(fields);
                }
                self.rows.insert(row.id, merged);
            }
            Change::Patch(row) => {
                let old = &self.rows[&row.id];
                assert!(!old.open);
                assert_eq!(row.rev, old.rev + 1);
                assert_eq!((row.turn, row.group), (old.turn, old.group));
                assert_eq!(row.fields.get("hidden").map(String::as_str), Some("true"));
                self.text.remove(&row.id);
                self.rows.insert(row.id, row.clone());
            }
            Change::Body { id, field, append, source } => {
                assert!(self.rows[id].open);
                let s = match source {
                    BodySource::Text(s) => {
                        assert!(s.len() <= 16 * 1024);
                        s.clone()
                    }
                    BodySource::Input(r) => {
                        let raw: &serde_json::value::RawValue =
                            input::parse(&bytes[r.offset..r.offset + r.length]).unwrap();
                        self.raw.insert((*id, format!("{field:?}")), raw.get().into());
                        let mut s = String::new();
                        if matches!(field, BodyField::Text | BodyField::Content) {
                            input::content(raw, 0, &mut |t| {
                                s.push_str(t);
                                Ok(())
                            })
                            .unwrap();
                        }
                        s
                    }
                };
                if matches!(field, BodyField::Text | BodyField::Content) {
                    let text = self.text.entry(*id).or_default();
                    if !append {
                        text.clear()
                    }
                    text.push_str(&s);
                }
            }
        }
    }
    fn line(&mut self, state: &mut State, harness: Harness, line: &str) -> Vec<Op> {
        let ops = translate(state, harness, line.as_bytes()).unwrap();
        for op in &ops {
            self.apply(op, line.as_bytes())
        }
        ops
    }
    fn visible(&self, row: &OwnedRow) -> bool {
        if row.fields.get("hidden").is_some_and(|v| v == "true") {
            return false;
        }
        let Some(group) = row.group else {
            return true;
        };
        let g = &self.rows[&group];
        if g.open {
            return true;
        }
        let runs: Vec<[u64; 2]> =
            serde_json::from_str(g.fields.get("out").map(String::as_str).unwrap_or("[]")).unwrap();
        runs.iter().any(|r| r[0] <= row.id && row.id <= r[1])
    }
    fn reply(&self, text: &str) -> &OwnedRow {
        let id = self
            .text
            .iter()
            .find(|(_, s)| s.as_str() == text)
            .map(|(id, _)| id)
            .unwrap_or_else(|| panic!("missing {text:?}: {:?}", self.text));
        &self.rows[id]
    }
}
fn quote(s: &str) -> String {
    serde_json::to_string(s).unwrap()
}
fn update(seq: u64, payload: &str) -> String {
    format!(
        r#"{{"seq":{seq},"at":1000,"dir":"in","kind":"session/update","msg":{{"method":"session/update","params":{{"update":{payload}}}}}}}"#
    )
}
fn mux(seq: u64, kind: &str, msg: &str) -> String {
    format!(r#"{{"seq":{seq},"at":1000,"dir":"mux","kind":"{kind}","msg":{msg}}}"#)
}
fn chunk(seq: u64, text: &str, key: &str) -> String {
    update(
        seq,
        &format!(
            r#"{{"sessionUpdate":"agent_message_chunk","messageId":{},"content":{{"type":"text","text":{}}}}}"#,
            quote(key),
            quote(text)
        ),
    )
}
fn replay(lines: &[String]) -> (State, Mirror) {
    let mut s = State::default();
    let mut m = Mirror::default();
    for l in lines {
        m.line(&mut s, Harness::V1, l);
    }
    (s, m)
}
#[test]
fn seed_words_and_background_tools_keep_their_ids() {
    let lines: Vec<_> = SEED.lines().map(str::to_owned).collect();
    let (s, m) = replay(&lines);
    assert_eq!(m.reply("Done.").turn, Some(1));
    assert!(m.visible(m.reply("Done.")));
    assert_eq!(m.reply("fn a() {}").kind, RowKind::Tool);
    assert_eq!(s.open_rows().filter(|r| r.open).count(), 0);
    let lines = [
        mux(1, "user_message", r#"{"text":"q","turnId":"t"}"#),
        update(2, r#"{"sessionUpdate":"tool_call","toolCallId":"bg","status":"running"}"#),
        mux(3, "turn_result", r#"{"turnId":"t"}"#),
        mux(4, "user_message", r#"{"text":"next","turnId":"next"}"#),
        update(
            5,
            r#"{"sessionUpdate":"tool_call_update","toolCallId":"bg","status":"completed","content":"result"}"#,
        ),
    ];
    let (_, m) = replay(&lines);
    let tool = m.reply("result");
    assert_eq!(tool.turn, Some(1));
    assert!(!tool.open);
    assert_eq!(m.rows.values().filter(|r| r.kind == RowKind::Tool).count(), 1);
}
#[test]
fn r1_recorded_replies_stay_under_their_person_prompt() {
    for fixture in
        [include_str!("fixtures/r1-reply-1.ndjson"), include_str!("fixtures/r1-reply-2.ndjson")]
    {
        let lines: Vec<_> = fixture.lines().map(str::to_owned).collect();
        let (_, m) = replay(&lines);
        let prompt = m.reply("in this case you didnt respond to me at all...");
        let answer = m.reply(ANSWER);
        assert_eq!(answer.turn, Some(prompt.id));
        assert!(m.visible(answer));
        assert!(answer.id > prompt.id);
        assert!(!m.text.values().any(|s| s.contains("Reading ws-deploy")));
        assert!(!m.rows.values().any(|r| r.fields.get("callId") == Some(&quote("read-9"))));
    }
}
#[derive(Default)]
struct Stretch {
    replies: Vec<String>,
    takeaways: Vec<bool>,
    stepped: bool,
    worked: bool,
    work_at: usize,
    steered: bool,
}
struct Chat {
    lines: Vec<String>,
}
impl Chat {
    fn mux(&mut self, k: &str, m: &str) {
        self.lines.push(mux(self.lines.len() as u64 + 1, k, m));
    }
    fn update(&mut self, p: &str) {
        self.lines.push(update(self.lines.len() as u64 + 1, p));
    }
    fn say(&mut self, t: &str, k: &str) {
        self.lines.push(chunk(self.lines.len() as u64 + 1, t, k));
    }
    fn progress(&mut self, task: bool) {
        self.update(if task {
            r#"{"sessionUpdate":"task_progress","taskId":"watch","status":"running"}"#
        } else {
            r#"{"sessionUpdate":"subagent_progress","subagentSessionId":"coord/helper"}"#
        });
    }
}
fn chat(seed: u32) -> (Vec<String>, Vec<Stretch>) {
    let mut rng = seed;
    let mut pick = |n: u32| {
        rng = rng.wrapping_mul(1664525).wrapping_add(1013904223);
        rng % n
    };
    let mut c = Chat { lines: Vec::new() };
    let mut stretches = Vec::new();
    let mut calls = 0;
    for t in 0..1 + pick(4) {
        let notice = t > 0 && pick(3) == 0;
        c.mux(
            "user_message",
            &format!(
                r#"{{"text":"Prompt {seed}-{t}","_meta":{{"provenance":{{"kind":"{}"}}}}}}"#,
                if notice { "inbox_notice" } else { "human" }
            ),
        );
        c.mux("turn_started", "{}");
        let mut stretch = Stretch::default();
        let mut open = false;
        let mut message = String::new();
        for step in 0..1 + pick(10) {
            match pick(7) {
                0 | 1 => {
                    let full = pick(2) == 0;
                    let words = if full {
                        format!(
                            "Reply {seed}-{t}-{step}: the fix is in.\n\nCI is green at its head."
                        )
                    } else {
                        format!("Note {seed}-{t}-{step}: checking.")
                    };
                    stretch.stepped = false;
                    if !open {
                        message = format!("msg-{seed}-{t}-{step}");
                        stretch.replies.push(words.clone());
                        stretch.takeaways.push(full);
                    } else {
                        stretch.replies.last_mut().unwrap().push_str(&format!(" {words}"));
                        *stretch.takeaways.last_mut().unwrap() |= full;
                    }
                    let cut = 1 + pick(words.len() as u32 - 1) as usize;
                    c.say(&format!("{}{}", if open { " " } else { "" }, &words[..cut]), &message);
                    if pick(2) != 0 {
                        c.progress(pick(2) != 0)
                    }
                    c.say(&words[cut..], &message);
                    open = true;
                }
                2 | 3 => {
                    calls += 1;
                    let title = if pick(2) != 0 { "send_message" } else { "run_tests" };
                    c.update(&format!(r#"{{"sessionUpdate":"tool_call","toolCallId":"c{calls}","title":"{title}","kind":"execute","status":"in_progress"}}"#));
                    c.update(&format!(r#"{{"sessionUpdate":"tool_call_update","toolCallId":"c{calls}","status":"completed"}}"#));
                    stretch.stepped = true;
                    stretch.worked = true;
                    stretch.work_at = stretch.replies.len();
                    open = false;
                }
                4 => c.progress(false),
                5 => c.progress(true),
                _ => {
                    c.mux("user_message",&format!(r#"{{"text":"Steer {seed}-{t}-{step}: also check CI","promptId":"p-{seed}-{t}-{step}","steer":true}}"#));
                    c.mux("steer_read", &format!(r#"{{"promptId":"p-{seed}-{t}-{step}"}}"#));
                    stretch.steered = true;
                }
            }
        }
        c.mux("turn_result", r#"{"status":"completed"}"#);
        stretches.push(stretch);
    }
    (c.lines, stretches)
}
#[test]
fn th_ten_thousand_random_splits_restore_identical_ops_and_final_replies() {
    for seed in 1..=10_000 {
        let (lines, stretches) = chat(seed);
        let (whole, view) = replay(&lines);
        let cut = (seed as usize * 7919) % (lines.len() + 1);
        let mut split = State::default();
        let mut split_view = Mirror::default();
        for line in &lines[..cut] {
            split_view.line(&mut split, Harness::V1, line);
        }
        let checkpoint = split.checkpoint().unwrap();
        split = State::restore(&checkpoint).unwrap();
        let mut killed = State::restore(&checkpoint).unwrap();
        for line in &lines[cut..] {
            let ops = split_view.line(&mut split, Harness::V1, line);
            assert_eq!(ops, translate(&mut killed, Harness::V1, line.as_bytes()).unwrap());
        }
        assert_eq!(whole, split);
        assert_eq!(view, split_view);
        let mut floor = 0;
        for stretch in stretches {
            let answer = if stretch.worked && !stretch.steered {
                stretch
                    .replies
                    .iter()
                    .enumerate()
                    .skip(stretch.work_at)
                    .zip(&stretch.takeaways)
                    .rev()
                    .find_map(|((_, s), t)| t.then_some(s))
                    .or_else(|| stretch.replies.get(stretch.work_at..).and_then(|r| r.last()))
            } else {
                stretch.replies.last()
            };
            if let Some(answer) = answer {
                let row = view.reply(answer);
                assert!(row.id > floor, "seed {seed}");
                assert!(
                    view.visible(row),
                    "seed {seed} row {:?} group {:?}",
                    row,
                    row.group.and_then(|id| view.rows.get(&id))
                );
                floor = row.id;
            }
            for reply in stretch.replies {
                assert_eq!(view.text.values().filter(|s| *s == &reply).count(), 1);
            }
        }
    }
}

#[test]
fn claude_split_property_and_final_reply_visibility() {
    let lines = [
        r#"{"type":"user","uuid":"p","message":{"content":"Question"}}"#,
        r#"{"type":"assistant","message":{"id":"a","content":[{"type":"text","text":"Working note."},{"type":"tool_use","id":"t","name":"Read","input":{"path":"a"}}]}}"#,
        r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"output"}]}}"#,
        r#"{"type":"assistant","message":{"id":"a","content":[{"type":"text","text":"Final answer?"}],"stop_reason":"end_turn"}}"#,
    ];
    let mut whole = State::default();
    let mut full = Mirror::default();
    for line in lines {
        full.line(&mut whole, Harness::Claude, line);
    }
    for seed in 1..=10_000usize {
        let cut = seed % (lines.len() + 1);
        let mut state = State::default();
        let mut view = Mirror::default();
        for line in &lines[..cut] {
            view.line(&mut state, Harness::Claude, line);
        }
        state = State::restore(&state.checkpoint().unwrap()).unwrap();
        for line in &lines[cut..] {
            view.line(&mut state, Harness::Claude, line);
        }
        assert_eq!(state, whole);
        assert_eq!(view, full);
    }
    let note = full.reply("Working note.");
    let answer = full.reply("Final answer?");
    assert!(full.visible(note));
    assert!(full.visible(answer));
    assert!(note.id < answer.id);
}

#[test]
fn malformed_harness_lines_are_counted_and_do_not_block_replay() {
    let mut state = State::default();
    assert!(translate(&mut state, Harness::Claude, br#"{"type":7}"#).is_ok());
    assert_eq!(state.counters().invalid_records, 1);
    assert!(translate(&mut state, Harness::V1, br#"not-json"#).is_ok());
    assert_eq!(state.counters().invalid_records, 2);
}

#[test]
fn duplicate_sequences_are_noops_but_new_replayed_prompts_start_a_turn() {
    let line = mux(1, "user_message", r#"{"text":"first","promptId":"p","turnId":"t1"}"#);
    let mut state = State::default();
    translate(&mut state, Harness::V1, line.as_bytes()).unwrap();
    let before = state.clone();
    let duplicate = translate(&mut state, Harness::V1, line.as_bytes()).unwrap();
    assert!(duplicate.is_empty());
    assert_eq!(state, before);
    let end = mux(2, "turn_result", r#"{"turnId":"t1"}"#);
    translate(&mut state, Harness::V1, end.as_bytes()).unwrap();
    let replay = mux(3, "user_message", r#"{"text":"second","promptId":"p","turnId":"t2"}"#);
    let ops = translate(&mut state, Harness::V1, replay.as_bytes()).unwrap();
    assert!(!ops.is_empty());
    assert_eq!(state.counters().replayed_prompts, 1);
    assert!(state.turn.is_some_and(|id| id > before.last_id));
}

#[test]
fn long_metadata_is_cut_without_a_late_line_error() {
    let long = "x".repeat(64 * 1024);
    let v1 = update(
        1,
        &format!(
            r#"{{"sessionUpdate":"tool_call","toolCallId":"t","status":"running","_meta":{{"claude":{{"tool":{}}}}}}}"#,
            quote(&long)
        ),
    );
    let mut state = State::default();
    let before = state.checkpoint().unwrap();
    assert!(translate(&mut state, Harness::V1, v1.as_bytes()).is_ok());
    assert!(state.counters().cut_fields > 0);
    assert_eq!(state.counters().line_errors, 0);
    let after = state.checkpoint().unwrap();
    assert_ne!(before, after);

    let malformed = br#"{"type":"assistant","message":{"content":7}}"#;
    let before = state.checkpoint().unwrap();
    assert!(translate(&mut state, Harness::Claude, malformed).is_ok());
    assert_eq!(state.checkpoint().unwrap(), before);
    assert_eq!(state.counters().line_errors, 0);
}
#[test]
fn large_tool_bodies_are_ranges_and_streamed_replies_have_small_checkpoints() {
    for harness in [Harness::V1, Harness::Claude] {
        let big = "x".repeat(5 * 1024 * 1024);
        let line = if harness == Harness::V1 {
            update(
                1,
                &format!(
                    r#"{{"sessionUpdate":"tool_call","toolCallId":"t","content":{}}}"#,
                    quote(&big)
                ),
            )
        } else {
            format!(
                r#"{{"type":"assistant","message":{{"content":[{{"type":"tool_use","id":"t","name":"Read","input":{}}}]}}}}"#,
                quote(&big)
            )
        };
        let mut s = State::default();
        let ops = translate(&mut s, harness, line.as_bytes()).unwrap();
        assert!(s.checkpoint().unwrap().len() < 1024 * s.open_rows().count());
        assert!(ops.iter().any(|o|matches!(o.change,Change::Body{source:BodySource::Input(r),..} if r.length>=5*1024*1024)));
        assert!(ops.iter().all(
            |o| !matches!(&o.change,Change::Body{source:BodySource::Text(t),..} if t.len()>16*1024)
        ));
    }
    let mut s = State::default();
    let mut m = Mirror::default();
    let mut all = String::new();
    for i in 1..=200 {
        let text = format!("{}\n\n", "y".repeat(1024));
        all.push_str(&text);
        m.line(&mut s, Harness::V1, &chunk(i, &text, "reply"));
        assert!(s.checkpoint().unwrap().len() < 1024 * s.open_rows().count());
    }
    let got = m
        .rows
        .values()
        .filter(|r| r.kind == RowKind::Text)
        .map(|r| {
            assert!(m.visible(r));
            m.text[&r.id].as_str()
        })
        .collect::<String>();
    assert_eq!(all, got);
    assert!(m.rows.values().filter(|r| r.kind == RowKind::Text).count() > 20);
}
#[test]
fn long_fence_continuations_carry_the_marker_and_replay_at_every_chunk() {
    let mut s = State::default();
    let mut m = Mirror::default();
    let text = format!("```rust\n{}\n{}\n```\n\n", "x".repeat(17 * 1024), "y".repeat(400));
    let mut seq = 0;
    for piece in text.as_bytes().chunks(71) {
        seq += 1;
        m.line(&mut s, Harness::V1, &chunk(seq, std::str::from_utf8(piece).unwrap(), "f"));
        s = State::restore(&s.checkpoint().unwrap()).unwrap();
    }
    assert!(m.rows.values().any(|r| r.fields.get("fence") == Some(&quote("```"))));
    let got = m
        .rows
        .values()
        .filter(|r| r.kind == RowKind::Text)
        .map(|r| m.text[&r.id].as_str())
        .collect::<String>();
    assert_eq!(text, got);
}
#[test]
fn malformed_input_is_transactional_and_raw_ranges_preserve_escapes() {
    let mut s = State::default();
    let bad = update(
        1,
        r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\ud800"}}"#,
    );
    assert!(translate(&mut s, Harness::V1, bad.as_bytes()).is_ok());
    assert_eq!(s.counters().invalid_records, 1);
    assert_eq!(s.last_row_id(), 0);
    let mut m = Mirror::default();
    m.line(&mut s, Harness::V1, &chunk(1, "🙂\n\"\\", "m"));
    assert!(m.visible(m.reply("🙂\n\"\\")));
    let checkpoint = s.checkpoint().unwrap();
    for n in 0..checkpoint.len() {
        assert!(State::restore(&checkpoint[..n]).is_err())
    }
}
#[test]
fn claude_string_reply_and_late_v1_final_are_visible() {
    let mut s = State::default();
    let mut m = Mirror::default();
    m.line(&mut s,Harness::Claude,r#"{"type":"assistant","timestamp":"2026-11-12T07:51:39Z","message":{"content":"Final reply","stop_reason":"end_turn"}}"#);
    assert!(m.visible(m.reply("Final reply")));
    assert!(!m.reply("Final reply").open);
    let (_, m) = replay(&[
        mux(1, "user_message", r#"{"text":"q","turnId":"t"}"#),
        mux(2, "turn_result", r#"{"turnId":"t"}"#),
        mux(3, "host_notice", r#"{"text":"background finished"}"#),
        chunk(4, "FINAL", "m"),
    ]);
    assert_eq!(m.reply("FINAL").turn, Some(1));
}

#[test]
fn live_steer_reserves_its_place_before_the_answer_with_every_echo_order() {
    for queued in [false, true] {
        for late in [false, true] {
            for read_first in [false, true] {
                let mut c = Chat { lines: Vec::new() };
                c.mux("user_message",r#"{"text":"Background completed","turnId":"t","_meta":{"provenance":{"kind":"task_notification"}}}"#);
                if queued {
                    c.mux("queued", r#"{"text":"Also check CI","promptId":"s"}"#);
                }
                let echo = r#"{"text":"Also check CI","promptId":"s","turnId":"t","steer":true}"#;
                if !late {
                    c.mux("user_message", echo);
                }
                if read_first {
                    c.mux("steer_read", r#"{"promptId":"s","turnId":"t"}"#);
                }
                c.update(r#"{"sessionUpdate":"tool_call","toolCallId":"c","status":"completed"}"#);
                if !read_first {
                    c.mux("steer_read", r#"{"promptId":"s","turnId":"t"}"#);
                }
                c.say("CI is green.", "m");
                c.mux("turn_result", r#"{"turnId":"t"}"#);
                if late {
                    c.mux("user_message", echo);
                }
                let (_, m) = replay(&c.lines);
                let steer = m.reply("Also check CI");
                let reply = m.reply("CI is green.");
                assert!(steer.id < reply.id);
                assert_eq!(steer.turn, reply.turn);
                assert_eq!(m.text.values().filter(|s| s.as_str() == "Also check CI").count(), 1);
            }
        }
    }
}

#[test]
fn group_decides_visibility_once_after_later_work_and_steers() {
    let a = "Takeaway A\n\nThe first result.";
    let b = "Takeaway B\n\nThe final result.";
    let (_, m) = replay(&[
        mux(1, "user_message", r#"{"text":"q"}"#),
        chunk(2, a, "a"),
        update(3, r#"{"sessionUpdate":"tool_call","toolCallId":"c","status":"completed"}"#),
        chunk(4, b, "b"),
        mux(5, "turn_result", "{}"),
    ]);
    assert!(!m.visible(m.reply(a)));
    assert!(m.visible(m.reply(b)));
    let (_, m) = replay(&[
        mux(1, "user_message", r#"{"text":"q"}"#),
        chunk(2, "Checking.", "n"),
        update(3, r#"{"sessionUpdate":"tool_call","toolCallId":"c","status":"completed"}"#),
        mux(4, "user_message", r#"{"text":"also check","steer":true,"promptId":"s"}"#),
        mux(5, "steer_read", r#"{"promptId":"s"}"#),
        mux(6, "turn_result", "{}"),
    ]);
    assert!(m.visible(m.reply("Checking.")));
}
#[test]
fn superseding_live_multiblock_reply_patches_only_its_settled_rows() {
    let mut c = Chat { lines: Vec::new() };
    c.mux("user_message", r#"{"text":"q"}"#);
    c.say(&format!("{}\n\n{}", "x".repeat(9000), "tail"), "old");
    c.mux("message_superseded", r#"{"oldMessageId":"old"}"#);
    c.say("Replacement.", "new");
    c.mux("turn_result", "{}");
    let (_, m) = replay(&c.lines);
    assert!(m.visible(m.reply("Replacement.")));
    assert!(!m.text.values().any(|s| s.contains('x')));
    assert!(m.rows.values().any(|r| r.rev == 2));
    assert!(
        m.rows
            .values()
            .filter(|r| r.fields.get("hidden") == Some(&"true".into()))
            .all(|r| r.as_row(r#"{"hidden":true}"#).est == 0)
    );
}

#[test]
fn an_unread_steer_becomes_the_next_prompt_in_its_reserved_place() {
    let lines = [
        mux(1, "user_message", r#"{"text":"first","turnId":"t1"}"#),
        mux(2, "user_message", r#"{"text":"next","promptId":"s","steer":true}"#),
        mux(3, "turn_result", r#"{"turnId":"t1"}"#),
        mux(4, "user_message", r#"{"text":"next","promptId":"s","turnId":"t2","steer":false}"#),
        chunk(5, "Next answer.", "m"),
        mux(6, "turn_result", r#"{"turnId":"t2"}"#),
    ];
    let mut s = State::default();
    let mut m = Mirror::default();
    m.line(&mut s, Harness::V1, &lines[0]);
    m.line(&mut s, Harness::V1, &lines[1]);
    let id = m.reply("next").id;
    assert!(m.reply("next").open);
    for line in &lines[2..] {
        m.line(&mut s, Harness::V1, line);
    }
    let next = m.reply("next");
    assert_eq!(next.id, id);
    assert_eq!(next.turn, Some(id));
    assert!(!next.open);
    assert_eq!(next.fields.get("steer").map(String::as_str), Some("false"));
    assert_eq!(m.reply("Next answer.").turn, Some(id));
}
#[test]
fn a_later_notice_prevents_a_reply_continuation_from_moving_below_it() {
    let mut c = Chat { lines: Vec::new() };
    c.mux("user_message", r#"{"text":"q"}"#);
    c.say("Start. ", "m");
    c.mux("host_notice", r#"{"text":"A later notice"}"#);
    for _ in 0..200 {
        c.say(&format!("{}\n\n", "x".repeat(1024)), "m");
    }
    c.mux("turn_result", "{}");
    let (_, m) = replay(&c.lines);
    let texts: Vec<_> = m.rows.values().filter(|r| r.kind == RowKind::Text).collect();
    assert_eq!(texts.len(), 1);
    assert!(texts[0].id < m.reply("A later notice").id);
    assert!(m.visible(texts[0]));
}

#[test]
fn checkpoint_and_open_rows_are_bounded_at_both_caps() {
    let mut c = Chat { lines: Vec::new() };
    c.mux("user_message", r#"{"text":"q"}"#);
    for n in 0..64 {
        c.update(&format!(
            r#"{{"sessionUpdate":"tool_call","toolCallId":"tool-{n}","status":"running"}}"#
        ));
    }
    for n in 0..32 {
        c.mux(
            "user_message",
            &format!(r#"{{"text":"steer-{n}","promptId":"s-{n}","steer":true}}"#),
        );
    }
    let (mut s, mut m) = replay(&c.lines);
    assert_eq!(s.open_rows().count(), 97);
    assert!(s.checkpoint().unwrap().len() < 32 * 1024);
    let first_tool = m.rows.values().find(|r| r.kind == RowKind::Tool).unwrap().id;
    m.line(
        &mut s,
        Harness::V1,
        &update(
            c.lines.len() as u64 + 1,
            r#"{"sessionUpdate":"tool_call","toolCallId":"overflow","status":"running"}"#,
        ),
    );
    assert!(!m.rows[&first_tool].open);
    assert_eq!(s.forced_rows, 1);
    assert_eq!(s.open_rows().count(), 97);
    m.line(
        &mut s,
        Harness::V1,
        &mux(
            c.lines.len() as u64 + 2,
            "user_message",
            r#"{"text":"overflow steer","promptId":"overflow","steer":true}"#,
        ),
    );
    assert!(!m.reply("steer-0").open);
    assert_eq!(s.forced_steers, 1);
    assert_eq!(s.prompts.len(), 32);
    assert_eq!(State::restore(&s.checkpoint().unwrap()).unwrap(), s);
}
#[test]
fn read_before_text_survives_another_turn_and_nonsteer_echo() {
    let mut c = Chat { lines: Vec::new() };
    c.mux("user_message", r#"{"text":"first","turnId":"t1"}"#);
    c.say("Before steer.", "before");
    c.mux("steer_read", r#"{"promptId":"s","turnId":"t1"}"#);
    c.say("Answer to steer.", "answer");
    c.mux("turn_result", r#"{"turnId":"t1"}"#);
    c.mux("user_message", r#"{"text":"another prompt","turnId":"t2"}"#);
    c.mux("user_message", r#"{"text":"late echo","promptId":"s","turnId":"t1"}"#);
    let (s, m) = replay(&c.lines);
    let echo = m.reply("late echo");
    let answer = m.reply("Answer to steer.");
    assert_eq!(echo.turn, answer.turn);
    assert!(echo.id < answer.id);
    assert!(!echo.open);
    assert_eq!(s.turn, Some(m.reply("another prompt").id));
    assert!(m.visible(m.reply("Before steer.")));
}

#[test]
fn session_exit_settles_live_bodies_and_hides_a_textless_steer() {
    let (_, m) = replay(&[
        mux(1, "user_message", r#"{"text":"q"}"#),
        update(2, r#"{"sessionUpdate":"tool_call","toolCallId":"t","status":"running"}"#),
        mux(3, "steer_read", r#"{"promptId":"no-echo"}"#),
        mux(4, "exited", "{}"),
    ]);
    assert!(m.rows.values().all(|r| !r.open));
    assert!(m.rows.values().any(|r|r.kind==RowKind::User&&r.fields.get("hidden").is_some_and(|v|v=="true")));
}
#[test]
fn missing_claude_tool_ids_never_coalesce_into_an_empty_identity() {
    let mut s = State::default();
    let line = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#;
    let ops = translate(&mut s, Harness::Claude, line.as_bytes()).unwrap();
    assert!(ops.is_empty());
    assert!(s.tools.is_empty());
}

#[test]
fn claude_null_stop_reason_keeps_the_reply_open() {
    let mut s = State::default();
    let mut m = Mirror::default();
    m.line(&mut s, Harness::Claude, r#"{"type":"user","uuid":"p","message":{"content":"q"}}"#);
    m.line(&mut s, Harness::Claude, r#"{"type":"assistant","message":{"id":"a","content":[{"type":"text","text":"hello"}],"stop_reason":null}}"#);
    assert!(m.reply("hello").open);
    m.line(&mut s, Harness::Claude, r#"{"type":"assistant","message":{"id":"a","content":[{"type":"text","text":" world"}],"stop_reason":"end_turn"}}"#);
    assert!(!m.reply("hello world").open);
    assert!(m.visible(m.reply("hello world")));
}

fn split_text_rows(parts: &[&str]) -> Vec<(String, Option<String>, Option<String>)> {
    let mut s = State::default();
    let mut m = Mirror::default();
    m.line(&mut s, Harness::V1, &mux(1, "user_message", r#"{"text":"q","turnId":"t"}"#));
    for (i, part) in parts.iter().enumerate() {
        m.line(&mut s, Harness::V1, &chunk(i as u64 + 2, part, "reply"));
        s = State::restore(&s.checkpoint().unwrap()).unwrap();
    }
    m.line(&mut s, Harness::V1, &mux(parts.len() as u64 + 2, "turn_result", r#"{"turnId":"t"}"#));
    m.rows
        .values()
        .filter(|r| r.kind == RowKind::Text)
        .map(|row| {
            assert!(!row.open);
            assert!(m.visible(row), "every continuation is in G.out");
            let text = m.text.get(&row.id).cloned().unwrap_or_default();
            assert_eq!(row.bytes, text.len() as u64);
            (text, row.fields.get("insideLine").cloned(), row.fields.get("fence").cloned())
        })
        .collect()
}

#[test]
fn first_byte_cuts_are_identical_at_every_event_split() {
    let text = format!(
        "{}\n\n-x\n\n1986 was a year\n\n+note\n\n  indented\n\n\r\t\nanswer 🦀",
        "a".repeat(8193)
    );
    let expected = split_text_rows(&[&text]);
    assert_eq!(expected.len(), 2);
    assert_eq!(expected[1].0, "answer 🦀");
    for offset in (0..=text.len()).filter(|&i| text.is_char_boundary(i)) {
        assert_eq!(
            split_text_rows(&[&text[..offset], &text[offset..]]),
            expected,
            "split {offset}"
        );
    }
}

#[test]
fn large_reply_cut_offsets_do_not_depend_on_random_event_splits() {
    let text = format!("{}tail", format!("{}\n\n", "λ".repeat(511)).repeat(200));
    let expected = split_text_rows(&[&text]);
    for seed in 1..=32u64 {
        let mut random = seed;
        let mut offsets = vec![0];
        while *offsets.last().unwrap() < text.len() {
            random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
            let mut end = (offsets.last().unwrap() + 1 + (random as usize % 4096)).min(text.len());
            while end < text.len() && !text.is_char_boundary(end) {
                end += 1;
            }
            offsets.push(end);
        }
        let parts: Vec<_> = offsets.windows(2).map(|w| &text[w[0]..w[1]]).collect();
        assert_eq!(split_text_rows(&parts), expected, "seed {seed}");
    }
}

#[test]
fn hard_cut_preserves_utf8_and_reserves_continuation_before_a_notice() {
    let text = format!("{}🦀tail", "x".repeat(16 * 1024 - 1));
    let rows = split_text_rows(&[&text]);
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].0.len(), 16 * 1024 - 1);
    assert_eq!(rows[1].0, "🦀tail");
    assert_eq!(rows[1].1.as_deref(), Some("true"));
    let (_, m) = replay(&[
        mux(1, "user_message", r#"{"text":"q"}"#),
        chunk(2, &"x".repeat(16 * 1024), "m"),
        mux(3, "host_notice", r#"{"text":"notice"}"#),
        chunk(4, "tail", "m"),
        mux(5, "turn_result", "{}"),
    ]);
    assert!(m.reply("tail").id < m.reply("notice").id);
    assert!(m.visible(m.reply("tail")));
}

#[test]
fn a_queued_steer_belongs_to_the_turn_that_reads_it() {
    let (_, m) = replay(&[
        mux(1, "user_message", r#"{"text":"first","turnId":"t1"}"#),
        mux(2, "queued", r#"{"text":"steer","promptId":"s"}"#),
        mux(3, "user_message", r#"{"text":"second","turnId":"t2"}"#),
        mux(4, "steer_read", r#"{"promptId":"s"}"#),
        chunk(5, "answer", "m"),
        mux(6, "turn_result", r#"{"turnId":"t2"}"#),
    ]);
    assert_eq!(m.reply("steer").turn, Some(m.reply("second").id));
    assert!(m.reply("steer").id < m.reply("answer").id);
}

#[test]
fn turn_start_after_a_result_is_not_compared_with_the_old_turn() {
    let (_, m) = replay(&[
        mux(1, "user_message", r#"{"text":"one","turnId":"t1"}"#),
        mux(2, "turn_result", r#"{"turnId":"t1"}"#),
        mux(3, "turn_started", r#"{"turnId":"t2"}"#),
        mux(4, "user_message", r#"{"text":"two","turnId":"t2"}"#),
        chunk(5, "answer", "m"),
        mux(6, "turn_result", r#"{"turnId":"t2"}"#),
    ]);
    assert!(!m.reply("answer").open);
}
