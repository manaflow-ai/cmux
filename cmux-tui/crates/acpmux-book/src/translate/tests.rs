#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects,
    reason = "deterministic generated inputs and assertions"
)]
use super::*;
use serde::Deserialize;
use std::collections::BTreeSet;
fn t(state: &mut State, harness: Harness, bytes: &[u8]) -> Result<Vec<Op>, Error> {
    translate(state, harness, 0, 1, bytes)
}
const SEED: &str = include_str!("fixtures/seed-turn.ndjson");
const ANSWER: &str = "Sorry, that's frustrating. I did answer, but the chat drew the answer above your question, so it looked like I ignored you.\n\nMy answer was **no**, it shouldn't say cmux.";
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Mirror {
    rows: BTreeMap<u64, OwnedRow>,
    text: BTreeMap<u64, String>,
    raw: BTreeMap<(u64, String), String>,
    queue: BTreeMap<u64, QueueEntry>,
    queued_text: BTreeMap<(u64, u32), String>,
}
#[derive(Deserialize)]
struct MirrorEnvelope {
    msg: Option<MirrorMessage>,
}
#[derive(Deserialize)]
struct MirrorMessage {
    text: Option<String>,
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
                    .filter(|_| row.fields.get("hidden").is_none_or(|v| v != "true"))
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
            Change::Queue(QueueChange::Add(entry)) => {
                self.queue.insert(entry.id_hash, *entry);
                if let Ok(envelope) = serde_json::from_slice::<MirrorEnvelope>(bytes)
                    && let Some(text) = envelope.msg.and_then(|msg| msg.text)
                {
                    self.queued_text.insert((entry.place, entry.span), text);
                }
            }
            Change::Queue(QueueChange::Remove(hash)) => {
                self.queue.remove(hash);
            }
            Change::Queue(QueueChange::Order) => {}
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
                    BodySource::Raw { place, span } => self
                        .queued_text
                        .get(&(*place, u32::try_from(*span).unwrap_or(u32::MAX)))
                        .cloned()
                        .unwrap_or_default(),
                };
                if matches!(field, BodyField::Text | BodyField::Content) {
                    let text = self.text.entry(*id).or_default();
                    if !append {
                        text.clear();
                    }
                    text.push_str(&s);
                }
            }
        }
    }
    fn line(&mut self, state: &mut State, harness: Harness, line: &str) -> Vec<Op> {
        self.line_at(state, harness, 0, 1, line)
    }
    fn line_at(
        &mut self,
        state: &mut State,
        harness: Harness,
        place: u64,
        span: u64,
        line: &str,
    ) -> Vec<Op> {
        let ops = translate(state, harness, place, span, line.as_bytes()).unwrap();
        for op in &ops {
            self.apply(op, line.as_bytes());
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
    let mut place = 0;
    for l in lines {
        m.line_at(&mut s, Harness::V1, place, l.len() as u64, l);
        place = place.saturating_add(l.len() as u64);
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
    fn queue_add(&mut self, id: &str, pending: &mut Vec<String>) {
        self.mux("queued", &format!(r#"{{"text":"Queued {id}","promptId":"{id}"}}"#));
        if !pending.iter().any(|key| key == id) {
            pending.push(id.to_owned());
        }
    }
    fn queue_step(
        &mut self,
        pick: &mut impl FnMut(u32) -> u32,
        pending: &mut Vec<String>,
        late: &mut Vec<String>,
        id: &str,
    ) -> bool {
        match pick(7) {
            0 => {
                // Several entries may be held at once, across ordinary work.
                let second = format!("{id}-held");
                self.queue_add(id, pending);
                self.queue_add(&second, pending);
                self.mux("queue_paused", &format!(r#"{{"held":["{id}","{second}"]}}"#));
                false
            }
            1 if !pending.is_empty() => {
                let index = pick(pending.len() as u32) as usize;
                let id = pending.remove(index);
                self.mux("queue_resumed", &format!(r#"{{"promptIds":["{id}"]}}"#));
                let kind = if pick(2) == 0 { "dequeued" } else { "queue_removed" };
                self.mux(kind, &format!(r#"{{"promptId":"{id}"}}"#));
                false
            }
            order @ (2 | 3) if !pending.is_empty() => {
                let index = pick(pending.len() as u32) as usize;
                let id = pending.remove(index);
                if order == 2 {
                    self.mux("steer_read", &format!(r#"{{"promptId":"{id}"}}"#));
                }
                self.steer_echo(&id);
                if order == 3 {
                    self.mux("steer_read", &format!(r#"{{"promptId":"{id}"}}"#));
                }
                true
            }
            4 => {
                // A read can precede its queued record. It never becomes pending.
                self.mux("steer_read", &format!(r#"{{"promptId":"{id}"}}"#));
                self.mux("queued", &format!(r#"{{"text":"Queued {id}","promptId":"{id}"}}"#));
                self.steer_echo(id);
                true
            }
            5 => {
                // Keep this textless row open through a result and the next prompt.
                self.mux("steer_read", &format!(r#"{{"promptId":"{id}"}}"#));
                late.push(id.to_owned());
                true
            }
            _ => {
                // No queued record at all, including while a message streams.
                self.steer_echo(id);
                self.mux("steer_read", &format!(r#"{{"promptId":"{id}"}}"#));
                true
            }
        }
    }
    fn steer_echo(&mut self, id: &str) {
        self.mux(
            "user_message",
            &format!(r#"{{"text":"Steer {id}","promptId":"{id}","steer":true}}"#),
        );
    }
}
fn chat(seed: u32) -> (Vec<String>, Vec<Stretch>, Vec<String>) {
    let mut rng = seed;
    let mut pick = |n: u32| {
        rng = rng.wrapping_mul(1664525).wrapping_add(1013904223);
        rng % n
    };
    let mut c = Chat { lines: Vec::new() };
    let mut stretches = Vec::new();
    let mut calls = 0;
    let mut pending: Vec<String> = Vec::new();
    let mut late: Vec<String> = Vec::new();
    for t in 0..1 + pick(4) {
        let notice = t > 0 && pick(3) == 0;
        let prompt_id = if pending.is_empty() { None } else { Some(pending.remove(0)) };
        c.mux(
            "user_message",
            &match prompt_id.as_deref() {
                Some(id) => format!(
                    r#"{{"text":"Prompt {seed}-{t}","promptId":"{id}","_meta":{{"provenance":{{"kind":"{}"}}}}}}"#,
                    if notice { "inbox_notice" } else { "human" }
                ),
                None => format!(
                    r#"{{"text":"Prompt {seed}-{t}","_meta":{{"provenance":{{"kind":"{}"}}}}}}"#,
                    if notice { "inbox_notice" } else { "human" }
                ),
            },
        );
        c.mux("turn_started", "{}");
        let mut stretch = Stretch::default();
        let mut open = false;
        let mut message = String::new();

        for id in late.drain(..) {
            c.steer_echo(&id);
        }
        for step in 0..1 + pick(10) {
            match pick(10) {
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
                        c.progress(pick(2) != 0);
                    }
                    if pick(5) == 0 {
                        stretch.steered |= c.queue_step(
                            &mut pick,
                            &mut pending,
                            &mut late,
                            &format!("q-stream-{seed}-{t}-{step}"),
                        );
                    }
                    c.say(&words[cut..], &message);
                    open = true;
                }
                2 | 3 => {
                    calls += 1;
                    let title = if pick(2) != 0 { "send_message" } else { "run_tests" };
                    c.update(&format!(r#"{{"sessionUpdate":"tool_call","toolCallId":"c{calls}","title":"{title}","kind":"execute","status":"in_progress"}}"#));
                    if pick(3) == 0 {
                        stretch.steered |= c.queue_step(
                            &mut pick,
                            &mut pending,
                            &mut late,
                            &format!("q-call-{seed}-{t}-{step}"),
                        );
                    }
                    c.update(&format!(r#"{{"sessionUpdate":"tool_call_update","toolCallId":"c{calls}","status":"completed"}}"#));
                    stretch.stepped = true;
                    stretch.worked = true;
                    stretch.work_at = stretch.replies.len();
                    open = false;
                }
                4 => c.progress(false),
                5 => c.progress(true),
                _ => {
                    stretch.steered |= c.queue_step(
                        &mut pick,
                        &mut pending,
                        &mut late,
                        &format!("q-step-{seed}-{t}-{step}"),
                    );
                }
            }
        }
        c.mux("turn_result", r#"{"status":"completed"}"#);
        stretches.push(stretch);
    }
    // Final-turn textless reads get their echo after the result too.
    for id in late {
        c.steer_echo(&id);
    }
    (c.lines, stretches, pending)
}

fn assert_disjoint_group_ranges(mirror: &Mirror) {
    let mut previous_last = 0;
    for group in mirror.rows.values().filter(|row| row.kind == RowKind::Group) {
        assert!(
            group.id > previous_last,
            "group {} begins inside a preceding fold ending at {previous_last}",
            group.id
        );
        let last = if group.open {
            group.id
        } else {
            group.fields.get("last").unwrap().parse::<u64>().unwrap()
        };
        assert!(last >= group.id, "group {} ends before it begins", group.id);
        previous_last = last;
    }
}

#[test]
fn recorded_translation_fixtures_have_disjoint_fold_ranges() {
    for fixture in [
        SEED,
        include_str!("fixtures/r1-reply-1.ndjson"),
        include_str!("fixtures/r1-reply-2.ndjson"),
    ] {
        let mut state = State::default();
        let mut mirror = Mirror::default();
        let mut place = 0;
        for line in fixture.lines() {
            mirror.line_at(&mut state, Harness::V1, place, line.len() as u64, line);
            assert_disjoint_group_ranges(&mirror);
            place += line.len() as u64;
        }
    }
}

fn assert_settled_group_out(mirror: &Mirror) {
    assert_disjoint_group_ranges(mirror);
    for group in mirror.rows.values().filter(|row| row.kind == RowKind::Group && !row.open) {
        let last = group
            .fields
            .get("last")
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(group.id);
        let out: BTreeSet<u64> = serde_json::from_str::<Vec<[u64; 2]>>(
            group.fields.get("out").map(String::as_str).unwrap_or("[]"),
        )
        .unwrap()
        .into_iter()
        .flat_map(|[first, last]| first..=last)
        .collect();
        for id in &out {
            let row = &mirror.rows[id];
            assert_eq!(row.turn, group.turn, "out row {id} has the wrong turn");
        }
        let mut expected = out.clone();
        expected.insert(group.id);
        let actual: BTreeSet<u64> = mirror
            .rows
            .values()
            .filter(|row| {
                row.id >= group.id
                    && row.id <= last
                    && (row.id == group.id || (row.turn == group.turn && mirror.visible(row)))
            })
            .map(|row| row.id)
            .collect();
        assert_eq!(actual, expected, "settled group {} has incomplete out", group.id);
    }
}

#[test]
fn th_ten_thousand_random_splits_restore_identical_ops_and_final_replies() {
    for seed in 1..=10_000 {
        let (lines, stretches, pending) = chat(seed);
        let (whole, view) = replay(&lines);
        let cut = (seed as usize * 7919) % (lines.len() + 1);
        let mut split = State::default();
        let mut split_view = Mirror::default();
        let mut place = 0;
        for line in &lines[..cut] {
            split_view.line_at(&mut split, Harness::V1, place, line.len() as u64, line);
            place = place.saturating_add(line.len() as u64);
        }
        let checkpoint = split.checkpoint().unwrap();
        split = checkpoint.restore().unwrap();
        let mut killed = checkpoint.restore().unwrap();
        for line in &lines[cut..] {
            let ops = split_view.line_at(&mut split, Harness::V1, place, line.len() as u64, line);
            assert_eq!(
                ops,
                translate(&mut killed, Harness::V1, place, line.len() as u64, line.as_bytes())
                    .unwrap()
            );
            place = place.saturating_add(line.len() as u64);
        }
        assert_eq!(whole, split);
        assert_eq!(view, split_view);
        let expected_queue: BTreeSet<u64> = pending.iter().map(|id| prompt_hash(id)).collect();
        // The ops carry each entry, not the list's order: the mirror is compared by id.
        let whole_queue: BTreeMap<u64, QueueEntry> =
            whole.queue.iter().map(|entry| (entry.id_hash, *entry)).collect();
        assert_eq!(
            whole_queue.keys().copied().collect::<BTreeSet<_>>(),
            expected_queue,
            "seed {seed}"
        );
        assert_eq!(view.queue, whole_queue, "seed {seed}");
        assert_settled_group_out(&view);
        assert_disjoint_group_ranges(&split_view);
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
        state = state.checkpoint().unwrap().restore().unwrap();
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
    assert!(t(&mut state, Harness::Claude, br#"{"type":7}"#).is_ok());
    assert_eq!(state.counters().invalid_records, 1);
    assert!(t(&mut state, Harness::V1, br#"not-json"#).is_ok());
    assert_eq!(state.counters().invalid_records, 2);
}

fn json_value_end(bytes: &[u8], start: usize) -> Option<usize> {
    let first = *bytes.get(start)?;
    if first == b'"' {
        let mut escaped = false;
        for (offset, byte) in bytes.iter().enumerate().skip(start + 1) {
            if escaped {
                escaped = false;
            } else if *byte == b'\\' {
                escaped = true;
            } else if *byte == b'"' {
                return Some(offset + 1);
            }
        }
        return None;
    }
    if matches!(first, b'[' | b'{') {
        let mut depth = 0usize;
        let mut escaped = false;
        let mut string = false;
        for (offset, byte) in bytes.iter().enumerate().skip(start) {
            if string {
                if escaped {
                    escaped = false;
                } else if *byte == b'\\' {
                    escaped = true;
                } else if *byte == b'"' {
                    string = false;
                }
                continue;
            }
            match *byte {
                b'"' => string = true,
                b'[' | b'{' => depth = depth.saturating_add(1),
                b']' | b'}' => {
                    depth = depth.saturating_sub(1);
                    if depth == 0 {
                        return Some(offset + 1);
                    }
                }
                _ => {}
            }
        }
        return None;
    }
    let mut end = start;
    while let Some(byte) = bytes.get(end) {
        if matches!(byte, b',' | b'}' | b']' | b'\n' | b'\r') {
            break;
        }
        end += 1;
    }
    Some(end)
}

fn leaf_mutations(line: &str) -> Vec<Vec<u8>> {
    let bytes = line.as_bytes();
    let mut mutations = Vec::new();
    let replacements = [
        "7".to_owned(),
        format!("\"{}\"", "x".repeat(300)),
        "null".to_owned(),
        "[]".to_owned(),
        "{}".to_owned(),
    ];
    let mut colon = 0;
    while let Some(relative) =
        bytes.get(colon..).and_then(|tail| tail.iter().position(|b| *b == b':'))
    {
        colon += relative + 1;
        let mut start = colon;
        while bytes.get(start).is_some_and(u8::is_ascii_whitespace) {
            start += 1;
        }
        let Some(end) = json_value_end(bytes, start) else { break };
        if end > start {
            for replacement in &replacements {
                let mut mutated = Vec::with_capacity(bytes.len() + replacement.len());
                mutated.extend_from_slice(&bytes[..start]);
                mutated.extend_from_slice(replacement.as_bytes());
                mutated.extend_from_slice(&bytes[end..]);
                mutations.push(mutated);
            }
        }
        colon = end;
    }
    mutations
}

fn assert_leaf_mutations(harness: Harness, lines: &[String]) {
    let mut state = State::default();
    for line in lines {
        for mutated in leaf_mutations(line) {
            let mut candidate = state.clone();
            let before = candidate.checkpoint().unwrap();
            let invalid = candidate.counters().invalid_records;
            t(&mut candidate, harness, mutated.as_slice()).unwrap();
            if candidate.counters().invalid_records > invalid {
                assert_eq!(candidate.checkpoint().unwrap(), before, "invalid leaf changed state");
            }
            assert_eq!(candidate.counters().line_errors, 0, "leaf mutation caused a late error");
        }
        t(&mut state, harness, line.as_bytes()).unwrap();
    }
}

#[test]
fn every_json_leaf_is_total_and_does_not_mutate_on_rejection() {
    let mut v1 = Vec::new();
    for fixture in [
        SEED,
        include_str!("fixtures/r1-reply-1.ndjson"),
        include_str!("fixtures/r1-reply-2.ndjson"),
    ] {
        v1.extend(fixture.lines().map(str::to_owned));
    }
    for seed in 0..256 {
        v1.extend(chat(seed).0);
    }
    assert_leaf_mutations(Harness::V1, &v1);

    let claude = [
        r#"{"type":"user","uuid":"p","message":{"content":"Question"}}"#,
        r#"{"type":"assistant","message":{"id":"a","content":[{"type":"thinking","thinking":"reason"},{"type":"tool_use","id":"t","name":"Read","input":{"path":"a"}}]}}"#,
        r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"output"}]}}"#,
        r#"{"type":"assistant","message":{"id":"a","content":[{"type":"text","text":"Answer"}],"stop_reason":"end_turn"}}"#,
    ]
    .into_iter()
    .map(str::to_owned)
    .collect::<Vec<_>>();
    assert_leaf_mutations(Harness::Claude, &claude);
}

#[test]
fn duplicate_sequences_are_noops_but_new_replayed_prompts_start_a_turn() {
    let line = mux(1, "user_message", r#"{"text":"first","promptId":"p","turnId":"t1"}"#);
    let mut state = State::default();
    t(&mut state, Harness::V1, line.as_bytes()).unwrap();
    let before = state.clone();
    let duplicate = t(&mut state, Harness::V1, line.as_bytes()).unwrap();
    assert!(duplicate.is_empty());
    assert_eq!(state, before);
    let end = mux(2, "turn_result", r#"{"turnId":"t1"}"#);
    t(&mut state, Harness::V1, end.as_bytes()).unwrap();
    let replay = mux(3, "user_message", r#"{"text":"second","promptId":"p","turnId":"t2"}"#);
    let ops = t(&mut state, Harness::V1, replay.as_bytes()).unwrap();
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
    assert!(t(&mut state, Harness::V1, v1.as_bytes()).is_ok());
    assert!(state.counters().cut_fields > 0);
    assert_eq!(state.counters().line_errors, 0);
    let after = state.checkpoint().unwrap();
    assert_ne!(before, after);

    let malformed = br#"{"type":"assistant","message":{"content":7}}"#;
    let before = state.checkpoint().unwrap();
    assert!(t(&mut state, Harness::Claude, malformed).is_ok());
    assert_eq!(state.checkpoint().unwrap(), before);
    assert_eq!(state.counters().line_errors, 0);
}

#[test]
fn accepted_input_never_mutates_a_leaf_before_rejection() {
    let mut state = State::default();
    for seed in 0..10_000u32 {
        let before = state.checkpoint().unwrap();
        let line = if seed % 2 == 0 {
            br#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":7,"text":"ok"}]}}"#.to_vec()
        } else {
            br#"{"type":"assistant","message":{"content":7}}"#.to_vec()
        };
        assert!(t(&mut state, Harness::Claude, &line).is_ok());
        assert_eq!(state.checkpoint().unwrap(), before);
        assert_eq!(state.counters().line_errors, 0);
    }
    let before = state.checkpoint().unwrap();
    let segment = "x".repeat(64 * 1024);
    let line = update(
        1,
        &format!(
            r#"{{"sessionUpdate":"agent_message_chunk","messageId":"m","_meta":{{"acpmux":{{"segment":{}}}}},"content":{{"type":"text","text":"ok"}}}}"#,
            quote(&segment)
        ),
    );
    assert!(t(&mut state, Harness::V1, line.as_bytes()).is_ok());
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
        let ops = t(&mut s, harness, line.as_bytes()).unwrap();
        assert!(s.checkpoint().unwrap().translator.len() < 1024 * s.open_rows().count());
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
        assert!(s.checkpoint().unwrap().translator.len() < 1024 * s.open_rows().count());
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
        s = s.checkpoint().unwrap().restore().unwrap();
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
    assert!(t(&mut s, Harness::V1, bad.as_bytes()).is_ok());
    assert_eq!(s.counters().invalid_records, 1);
    assert_eq!(s.last_row_id(), 0);
    let mut m = Mirror::default();
    m.line(&mut s, Harness::V1, &chunk(1, "🙂\n\"\\", "m"));
    assert!(m.visible(m.reply("🙂\n\"\\")));
    let checkpoint = s.checkpoint().unwrap();
    for n in 0..checkpoint.translator.len() {
        assert!(State::restore(&checkpoint.translator[..n], &checkpoint.prompts).is_err());
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
    assert!(m.visible(m.reply("also check")));
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
    assert!(s.checkpoint().unwrap().translator.len() < 32 * 1024);
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
    assert_eq!(s.checkpoint().unwrap().restore().unwrap(), s);
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
fn read_before_late_text_is_in_the_settled_turn_out() {
    let lines = [
        mux(1, "user_message", r#"{"text":"first","turnId":"t1"}"#),
        mux(2, "steer_read", r#"{"promptId":"s","turnId":"t1"}"#),
        mux(3, "turn_result", r#"{"turnId":"t1"}"#),
        mux(4, "user_message", r#"{"text":"next","turnId":"t2"}"#),
        mux(5, "user_message", r#"{"text":"late","promptId":"s","turnId":"t1"}"#),
        mux(6, "turn_result", r#"{"turnId":"t2"}"#),
    ];
    let (_, mirror) = replay(&lines);
    let steer = mirror.reply("late");
    assert!(mirror.visible(steer));
    assert_eq!(steer.turn, Some(mirror.reply("first").id));
    let next = mirror.reply("next");
    let group = mirror
        .rows
        .values()
        .find(|row| row.kind == RowKind::Group && row.turn == next.turn)
        .unwrap();
    let out = |group: &OwnedRow| {
        serde_json::from_str::<Vec<[u64; 2]>>(group.fields.get("out").unwrap()).unwrap()
    };
    assert!(!out(group).iter().any(|[first, last]| (*first..=*last).contains(&steer.id)));
    let original = mirror
        .rows
        .values()
        .find(|row| row.kind == RowKind::Group && row.turn == steer.turn)
        .unwrap();
    assert!(out(original).iter().any(|[first, last]| (*first..=*last).contains(&steer.id)));
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
    let ops = t(&mut s, Harness::Claude, line.as_bytes()).unwrap();
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
        s = s.checkpoint().unwrap().restore().unwrap();
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
fn queued_entries_are_idempotent_bounded_and_raw() {
    let mut state = State::default();
    let first = mux(1, "user_message", r#"{"text":"first","promptId":"p","turnId":"t1"}"#);
    t(&mut state, Harness::V1, first.as_bytes()).unwrap();
    let queued = mux(2, "queued", r#"{"text":"hé","promptId":"q"}"#);
    let ops = translate(&mut state, Harness::V1, 700, 3, queued.as_bytes()).unwrap();
    assert!(ops.iter().any(|op| matches!(
        &op.change,
        Change::Queue(QueueChange::Add(entry))
            if entry.place == 700 && entry.span == 3 && entry.text_len == "hé".len() as u32
    )));
    assert_eq!(state.queue.len(), 1);
    let duplicate = translate(&mut state, Harness::V1, 700, 3, queued.as_bytes()).unwrap();
    assert!(duplicate.is_empty());

    let paused = mux(3, "queue_paused", r#"{"held":["q"]}"#);
    let paused_ops = translate(&mut state, Harness::V1, 701, 1, paused.as_bytes()).unwrap();
    assert!(paused_ops.iter().any(|op| matches!(
        &op.change,
        Change::Queue(QueueChange::Add(entry)) if entry.held()
    )));
    let resumed = mux(4, "queue_resumed", r#"{"promptIds":["q"]}"#);
    translate(&mut state, Harness::V1, 702, 1, resumed.as_bytes()).unwrap();
    assert!(!state.queue.first().unwrap().held());

    let read = mux(5, "steer_read", r#"{"promptId":"q"}"#);
    let read_ops = translate(&mut state, Harness::V1, 703, 1, read.as_bytes()).unwrap();
    assert!(read_ops.iter().any(|op| matches!(
        &op.change,
        Change::Body { source: BodySource::Raw { place: 700, span: 3 }, .. }
    )));
    assert!(state.queue.is_empty());
}

#[test]
fn queue_entries_are_removed_when_read_before_or_after_queue_record() {
    let mut state = State::default();
    let first = mux(1, "user_message", r#"{"text":"first","turnId":"t1"}"#);
    translate(&mut state, Harness::V1, 1, 1, first.as_bytes()).unwrap();
    let read = mux(2, "steer_read", r#"{"promptId":"late"}"#);
    translate(&mut state, Harness::V1, 2, 1, read.as_bytes()).unwrap();
    let queued = mux(3, "queued", r#"{"text":"late","promptId":"late"}"#);
    translate(&mut state, Harness::V1, 3, 1, queued.as_bytes()).unwrap();
    assert!(state.queue.is_empty());
    let echo = mux(4, "user_message", r#"{"text":"late","promptId":"late","steer":true}"#);
    translate(&mut state, Harness::V1, 4, 1, echo.as_bytes()).unwrap();
    let end = mux(5, "turn_result", r#"{"turnId":"t1"}"#);
    translate(&mut state, Harness::V1, 5, 1, end.as_bytes()).unwrap();
    let queued_again = mux(6, "queued", r#"{"text":"late","promptId":"late"}"#);
    translate(&mut state, Harness::V1, 6, 1, queued_again.as_bytes()).unwrap();
    assert!(state.queue.is_empty());
}

#[test]
fn queue_cap_counts_the_1025th_entry_without_holding_it() {
    let mut state = State::default();
    t(&mut state, Harness::V1, mux(1, "user_message", r#"{"text":"first"}"#).as_bytes()).unwrap();
    for n in 0..1025u64 {
        let line = mux(n + 2, "queued", &format!(r#"{{"text":"q-{n}","promptId":"q-{n}"}}"#));
        translate(&mut state, Harness::V1, n + 2, 1, line.as_bytes()).unwrap();
    }
    assert_eq!(state.queue.len(), 1024);
    assert_eq!(state.counters().queue_overflowed, 1);
    let saved = state.checkpoint().unwrap();
    assert_eq!(saved.prompts.len(), 1024);
    assert_eq!(saved.restore().unwrap(), state);
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

#[test]
fn in_turn_ends_with_the_turn_and_a_restore_agrees() {
    let mut s = State::default();
    assert!(!s.in_turn());
    let lines: Vec<_> = SEED.lines().collect();
    for (index, line) in lines.iter().enumerate() {
        t(&mut s, Harness::V1, line.as_bytes()).unwrap();
        // The seed's last line is its turn's result.
        assert_eq!(s.in_turn(), index + 1 < lines.len(), "line {index}");
        let restored = s.checkpoint().unwrap().restore().unwrap();
        assert_eq!(restored.in_turn(), s.in_turn(), "line {index}");
    }
    // A background tool's late update keeps the ended turn's id and starts no turn.
    let late = update(
        10,
        r#"{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed"}"#,
    );
    t(&mut s, Harness::V1, late.as_bytes()).unwrap();
    assert!(!s.in_turn());
    // A turn the daemon starts with no prompt is a turn until its result.
    t(&mut s, Harness::V1, mux(11, "turn_started", r#"{"turnId":"t2"}"#).as_bytes()).unwrap();
    assert!(s.in_turn());
    t(&mut s, Harness::V1, mux(12, "turn_result", r#"{"turnId":"t2"}"#).as_bytes()).unwrap();
    assert!(!s.in_turn());
}

#[test]
fn full_fixed_width_queue_fits_beside_a_translator_at_its_byte_bound() {
    let mut state = State::default();
    t(&mut state, Harness::V1, mux(1, "user_message", r#"{"text":"boundary"}"#).as_bytes())
        .unwrap();
    // Fill metadata, not a retained body, to test the codec's exact boundary.
    // Each field stays under the field cap; the particular names are immaterial.
    let mut n = 0;
    while MAX_TRANSLATOR_BYTES - state.checkpoint().unwrap().translator.len() > 200 {
        state.group.as_mut().unwrap().field(&format!("padding-{n}"), &"x".repeat(128));
        n += 1;
    }
    state.group.as_mut().unwrap().field("tail", "");
    let remaining = MAX_TRANSLATOR_BYTES - state.checkpoint().unwrap().translator.len();
    assert!(remaining < MAX_KEY_BYTES - 5);
    state.group.as_mut().unwrap().field("tail", &"x".repeat(remaining));
    let translator = state.checkpoint().unwrap().translator;
    assert_eq!(translator.len(), MAX_TRANSLATOR_BYTES);

    fill_queue(&mut state);
    let saved = state.checkpoint().unwrap();
    // The queue is absent from serde's translator segment, even when full.
    assert_eq!(saved.translator, translator);
    assert_eq!(saved.prompts.len(), MAX_QUEUE_ENTRIES);
    assert_eq!(saved.translator.len() + 32 * saved.prompts.len(), MAX_STATE_BYTES);
    assert_eq!(saved.restore().unwrap(), state);
    state.turn_key.push('x');
    assert!(matches!(state.checkpoint(), Err(Error::StateTooLarge { .. })));
}

fn fill_queue(state: &mut State) {
    for n in 0..MAX_QUEUE_ENTRIES as u64 {
        let entry = QueueEntry {
            id_hash: u64::MAX - n,
            at_state: u64::MAX,
            place: u64::MAX - n,
            span: u32::MAX,
            text_len: u32::MAX,
        };
        state.queue.push(entry);
    }
}

/// Every bounded part at its bound at once: the translator's segment, 1,024 waiting prompts
/// and the open bodies, in one book checkpoint.
#[test]
fn a_book_checkpoint_with_every_part_at_its_bound_fits_and_restores_the_queue() {
    use crate::blobs::{Blobs, Body};
    use crate::checkpoint::{Checkpoint, Cursor, OpenBody};
    use crate::log::{Log, Options, RawRange};
    let mut state = State::default();
    t(&mut state, Harness::V1, mux(1, "user_message", r#"{"text":"boundary"}"#).as_bytes())
        .unwrap();
    let mut n = 0;
    while MAX_TRANSLATOR_BYTES - state.checkpoint().unwrap().translator.len() > 200 {
        state.group.as_mut().unwrap().field(&format!("padding-{n}"), &"x".repeat(128));
        n += 1;
    }
    fill_queue(&mut state);
    let saved = state.checkpoint().unwrap();

    let home = tempfile::tempdir().unwrap();
    let (mut log, _) = Log::open(home.path(), Options::default()).unwrap();
    let source = log.append_raw_file(b"test").unwrap();
    let mut blobs = Blobs::open(home.path()).unwrap();
    let mut checkpoint = Checkpoint::new(VERSION);
    checkpoint.last_row = 64;
    checkpoint.translator = saved.translator.clone();
    checkpoint.prompts = saved.prompts.clone();
    checkpoint.cursors.push(Cursor { file: source, place: 100, stamp: 7 });
    checkpoint.summary = vec![b'x'; 2048];
    let large = format!("\"{}\"", "x".repeat(1 << 20));
    for row in 1..=64 {
        let mut body = Body::new(row).unwrap();
        blobs.set(&mut body, "text", &large, true).unwrap();
        for key in ["content", "input", "entries", "source", "images", "title"] {
            blobs.set(&mut body, key, "null", false).unwrap();
        }
        checkpoint.open.push(OpenBody { body, raw: RawRange { file: source, off: 1, len: 99 } });
    }
    blobs.sync(checkpoint.open.iter().map(|r| &r.body)).unwrap();
    let ids = checkpoint.open.iter().map(|r| r.body.row).collect::<Vec<_>>();
    checkpoint.write(&mut log, &ids).unwrap();
    assert!(std::fs::metadata(home.path().join("checkpoint")).unwrap().len() <= 96 * 1024);
    drop(log);
    let (_, recovered) = Log::open(home.path(), Options::default()).unwrap();
    let reopened = Checkpoint::from_recovered(&recovered).unwrap();
    let restored = State::restore(&reopened.translator, &reopened.prompts).unwrap();
    assert_eq!(restored, state);
    assert!(restored.queue().eq(state.queue()));
}

#[test]
fn unknown_checkpoint_version_requires_replay_from_raw() {
    let mut checkpoint = State::default().checkpoint().unwrap().translator;
    // Version 5 included an empty queue map in the serde segment; version 6 put the queue's
    // records after it; version 7 keeps them in the book's prompt section. The actor must
    // rebuild from raw, never guess an older layout.
    for old in [5, 6, VERSION as u8 + 1] {
        checkpoint[0] = old;
        assert_eq!(State::restore(&checkpoint, &[]), Err(Error::CheckpointVersion));
    }
}

fn queue_ids(state: &State) -> Vec<(u64, bool)> {
    state.queue().map(|entry| (entry.id_hash, entry.held())).collect()
}

fn ids(names: &[&str]) -> Vec<(u64, bool)> {
    names
        .iter()
        .map(|name| match name.strip_suffix('!') {
            Some(held) => (prompt_hash(held), true),
            None => (prompt_hash(name), false),
        })
        .collect()
}

/// Decision 215: the queue is v1's list order, as its restore reads the log.
#[test]
fn the_queue_keeps_v1s_list_order_through_reorders_holds_and_requeues() {
    let mut state = State::default();
    let mut seq = 0;
    let mut line = |state: &mut State, kind: &str, msg: &str| {
        seq += 1;
        translate(state, Harness::V1, seq * 100, 1, mux(seq, kind, msg).as_bytes()).unwrap()
    };
    line(&mut state, "user_message", r#"{"text":"running","turnId":"t0"}"#);
    for id in ["a", "b", "agent"] {
        line(&mut state, "queued", &format!(r#"{{"text":"{id}","promptId":"{id}"}}"#));
    }
    assert_eq!(queue_ids(&state), ids(&["a", "b", "agent"]));
    // A person's prompt goes ahead of an agent message: `queued`, then its `queue_order`.
    line(&mut state, "queued", r#"{"text":"c","promptId":"c"}"#);
    assert_eq!(queue_ids(&state), ids(&["a", "b", "agent", "c"]));
    let ops = line(&mut state, "queue_order", r#"{"promptId":"c","order":["a","b","c","agent"]}"#);
    assert!(ops.iter().any(|op| matches!(op.change, Change::Queue(QueueChange::Order))));
    assert_eq!(queue_ids(&state), ids(&["a", "b", "c", "agent"]));
    // Held and released in place.
    line(&mut state, "queue_paused", r#"{"held":["a","b"]}"#);
    assert_eq!(queue_ids(&state), ids(&["a!", "b!", "c", "agent"]));
    line(&mut state, "queue_resumed", r#"{"promptIds":["b"]}"#);
    assert_eq!(queue_ids(&state), ids(&["a!", "b", "c", "agent"]));
    // Sent now: released, and first.
    line(
        &mut state,
        "queue_order",
        r#"{"promptId":"a","next":true,"order":["a","b","c","agent"]}"#,
    );
    assert_eq!(queue_ids(&state), ids(&["a", "b", "c", "agent"]));
    line(&mut state, "queue_order", r#"{"order":["agent","nobody",7,"c"]}"#);
    // Named ones first in their order; unknown ids and non-strings skipped; the rest after.
    assert_eq!(queue_ids(&state), ids(&["agent", "c", "a", "b"]));
    // An order that names nothing, or is not a list, changes nothing.
    assert!(line(&mut state, "queue_order", r#"{"order":["nobody"]}"#).is_empty());
    assert!(line(&mut state, "queue_order", r#"{"order":"c"}"#).is_empty());
    // Requeued after a failed turn: at the end until the `queue_order` beside it.
    line(&mut state, "queued", r#"{"text":"agent","promptId":"agent","requeued":true}"#);
    assert_eq!(queue_ids(&state), ids(&["c", "a", "b", "agent"]));
    // An inbox digest's record carries the order with it in it.
    line(&mut state, "queued", r#"{"text":"d","promptId":"digest","order":["c","digest","a"]}"#);
    assert_eq!(queue_ids(&state), ids(&["c", "digest", "a", "b", "agent"]));
    line(&mut state, "dequeued", r#"{"promptId":"digest"}"#);
    assert_eq!(queue_ids(&state), ids(&["c", "a", "b", "agent"]));
    // A checkpoint keeps the order in its records, and a restore reads it back.
    let saved = state.checkpoint().unwrap();
    let restored = saved.restore().unwrap();
    assert_eq!(queue_ids(&restored), queue_ids(&state));
    // Two records for one prompt are damage.
    let mut twice = saved.clone();
    twice.prompts.push(twice.prompts[0]);
    assert_eq!(twice.restore(), Err(Error::CheckpointInvalid));
}

#[test]
fn a_reorder_of_a_full_queue_is_one_pass() {
    let mut state = State::default();
    t(&mut state, Harness::V1, mux(1, "user_message", r#"{"text":"first"}"#).as_bytes()).unwrap();
    for n in 0..1024u64 {
        let line = mux(n + 2, "queued", &format!(r#"{{"text":"q","promptId":"q-{n}"}}"#));
        translate(&mut state, Harness::V1, n + 2, 1, line.as_bytes()).unwrap();
    }
    let order: Vec<String> = (0..1024).rev().map(|n| format!("q-{n}")).collect();
    let line = mux(2000, "queue_order", &serde_json::json!({"order": order}).to_string());
    let started = std::time::Instant::now();
    translate(&mut state, Harness::V1, 2000, 1, line.as_bytes()).unwrap();
    let took = started.elapsed();
    let expected: Vec<u64> = (0..1024).rev().map(|n| prompt_hash(&format!("q-{n}"))).collect();
    assert_eq!(state.queue().map(|entry| entry.id_hash).collect::<Vec<_>>(), expected);
    assert!(took < std::time::Duration::from_millis(50), "a full reorder took {took:?}");
}
