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
                        (old.id, old.rev, old.at, old.turn),
                        (row.id, row.rev, row.at, row.turn)
                    );
                } else {
                    assert_eq!(row.id, self.rows.len() as u64 + 1);
                }
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
    assert_eq!(m.reply("Done.").group, None);
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
        assert_eq!(answer.group, None);
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
                    open = false;
                }
                4 => c.progress(false),
                5 => c.progress(true),
                _ => {
                    c.mux("user_message",&format!(r#"{{"text":"Steer {seed}-{t}-{step}: also check CI","promptId":"p-{seed}-{t}-{step}","steer":true}}"#));
                    c.mux("steer_read", &format!(r#"{{"promptId":"p-{seed}-{t}-{step}"}}"#));
                    stretch.steered = true;
                    stretches.push(stretch);
                    stretch = Stretch::default();
                    open = false;
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
            let answer = if stretch.stepped && !stretch.steered {
                stretch
                    .replies
                    .iter()
                    .zip(&stretch.takeaways)
                    .rev()
                    .find_map(|(s, t)| t.then_some(s))
            } else {
                stretch.replies.last()
            };
            if let Some(answer) = answer {
                let row = view.reply(answer);
                assert!(row.id > floor, "seed {seed}");
                assert_eq!(row.group, None, "seed {seed}");
                floor = row.id;
            }
            for reply in stretch.replies {
                assert_eq!(view.text.values().filter(|s| *s == &reply).count(), 1);
            }
        }
    }
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
        assert!(s.checkpoint().unwrap().len() < 1024);
    }
    let got = m
        .rows
        .values()
        .filter(|r| r.kind == RowKind::Text)
        .map(|r| {
            assert_eq!(r.group, None);
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
    let got = m.rows.values().map(|r| m.text[&r.id].as_str()).collect::<String>();
    assert_eq!(text, got);
}
#[test]
fn malformed_input_is_transactional_and_raw_ranges_preserve_escapes() {
    let mut s = State::default();
    let bad = update(
        1,
        r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\ud800"}}"#,
    );
    assert_eq!(translate(&mut s, Harness::V1, bad.as_bytes()), Err(Error::InvalidJson));
    assert_eq!(s, State::default());
    let mut m = Mirror::default();
    m.line(&mut s, Harness::V1, &chunk(1, "🙂\n\"\\", "m"));
    assert_eq!(m.reply("🙂\n\"\\").group, None);
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
    assert_eq!(m.reply("Final reply").group, None);
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
