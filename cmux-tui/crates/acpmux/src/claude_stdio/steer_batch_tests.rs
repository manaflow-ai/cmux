//! Other sessions' messages steered into one step go in as one line (`steer_batch.rs`). `Queue`
//! stands in for Claude Code's command queue, `cancel_async_message` included.

use super::steer_batch::BATCH_MAX_BYTES;
use super::*;

/// Claude Code's command queue during one long step.
#[derive(Default)]
struct Queue {
    waiting: Vec<Value>,
    /// Drops asked and not answered yet, so a test can answer them late or read a line first.
    drops: Vec<Value>,
}

impl Queue {
    /// Takes what acpmux wrote: user lines wait, drops are kept to answer.
    fn take(&mut self, lines: Vec<Value>) {
        for line in lines {
            match line["type"].as_str() {
                Some("user") => self.waiting.push(line),
                Some("control_request") if line["request"]["subtype"] == "cancel_async_message" => {
                    self.drops.push(line)
                }
                _ => {}
            }
        }
    }

    /// Answers every drop asked (dropping the line when it still waits), and takes what acpmux
    /// writes back, until nothing more comes; returns acpmux's answers to the hub.
    async fn settle(&mut self, t: &Translator) -> Vec<Message> {
        let mut out = Vec::new();
        while !self.drops.is_empty() {
            for drop in std::mem::take(&mut self.drops) {
                let uuid = &drop["request"]["message_uuid"];
                let before = self.waiting.len();
                self.waiting.retain(|l| &l["uuid"] != uuid);
                let cancelled = self.waiting.len() < before;
                let answer = json!({"type": "control_response", "response": {"subtype": "success", "request_id": drop["request_id"], "response": {"cancelled": cancelled}}});
                out.extend(t.inbound(&answer).await);
                self.take(t.take_stdin_replies().await);
            }
        }
        out
    }
}

fn steer(id: i64, text: &str, meta: Value) -> Message {
    let p =
        json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": text}], "_meta": meta});
    Message::request(id, method::SESSION_PROMPT, p)
}

/// Another session's message, as the hub marks it (`hub/steer_end.rs`).
fn from(id: i64, sender: &str, text: &str) -> Message {
    let meta = json!({"steer": true, "promptId": format!("p{id}"), "batch": {"from": sender}});
    steer(id, text, meta)
}

fn echo(line: &Value) -> Value {
    json!({"type": "user", "isReplay": true, "uuid": line["uuid"], "message": line["message"]})
}

fn text_of(line: &Value) -> String {
    let content = line["message"]["content"].as_array().cloned().unwrap_or_default();
    content.iter().filter_map(|b| b["text"].as_str()).collect()
}

fn answer(msgs: &[Message], want: i64) -> Option<Result<Value, String>> {
    msgs.iter().find_map(|m| match m {
        Message::Response { id, result, error } if *id == want => Some(match error {
            Some(e) => Err(e.message.clone()),
            None => Ok(result.clone().unwrap_or(Value::Null)),
        }),
        _ => None,
    })
}

/// A turn running its long step, its prompt read.
async fn stepping() -> (Arc<Translator>, Queue) {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let Outbound::Lines(first) = t.outbound(&steer(1, "long-step", json!({}))).await else {
        panic!()
    };
    t.inbound(&echo(&first[0])).await;
    (t, Queue::default())
}

async fn write(t: &Translator, q: &mut Queue, msg: &Message) {
    let Outbound::Lines(lines) = t.outbound(msg).await else { panic!("answered at once") };
    q.take(lines);
}

const SENDERS: [&str; 3] = ["lane-a", "lane-b", "lane-c"];

/// Ten messages from three sessions while the step runs: one line waits, and it holds every
/// message whole, under its sender, oldest first, after a line that says what it holds. Its echo
/// answers each message's own request.
#[tokio::test]
async fn ten_messages_during_a_step_wait_as_one_line_with_every_word_in_order() {
    let (t, mut q) = stepping().await;
    let mut answers = Vec::new();
    for i in 1..=10 {
        let sender = SENDERS[(i - 1) % 3];
        write(&t, &mut q, &from(i as i64 + 1, sender, &format!("message {i}\nsecond line"))).await;
        // Some drops are answered at once, some late: either way they end as one line.
        if i % 4 == 0 {
            answers.extend(q.settle(&t).await);
        }
    }
    answers.extend(q.settle(&t).await);
    assert_eq!(q.waiting.len(), 1, "one waiting line, not one per message: {:#?}", q.waiting);
    assert!(answers.is_empty(), "a message was answered before Claude Code read it: {answers:?}");
    let text = text_of(&q.waiting[0]);
    assert!(text.starts_with("10 messages from 3 sessions arrived during this step."), "{text}");
    let mut at = 0;
    for i in 1..=10 {
        let sender = SENDERS[(i - 1) % 3];
        for want in
            [format!("[message {i} of 10] from {sender}\n"), format!("message {i}\nsecond line")]
        {
            let found = text[at..]
                .find(&want)
                .unwrap_or_else(|| panic!("{want:?} missing or out of order in {text}"));
            at += found + want.len();
        }
    }
    let read = t.inbound(&echo(&q.waiting[0])).await;
    for id in 2..=11 {
        assert_eq!(answer(&read, id).unwrap().unwrap()["stopReason"], "steered", "{id}: {read:?}");
    }
}

/// The person's steer and one read now (`steerNow`) never wait for a drop: each is written at
/// once, its own line.
#[tokio::test]
async fn the_persons_steer_and_one_read_now_are_written_at_once() {
    let (t, mut q) = stepping().await;
    write(&t, &mut q, &from(2, "lane-a", "first")).await;
    write(&t, &mut q, &from(3, "lane-b", "second")).await;
    assert_eq!(q.drops.len(), 1, "the second joins the first");
    let person = steer(4, "use Rust", json!({"steer": true, "promptId": "p4"}));
    let Outbound::Lines(lines) = t.outbound(&person).await else { panic!() };
    assert_eq!(text_of(&lines[0]), "use Rust", "the person's steer waited: {lines:?}");
    q.take(lines);
    let mut urgent = from(5, "lane-c", "stop now");
    if let Message::Request { params: Some(p), .. } = &mut urgent {
        p["_meta"]["steerNow"] = json!(true);
    }
    let Outbound::Lines(lines) = t.outbound(&urgent).await else { panic!() };
    assert_eq!(text_of(&lines[0]), "stop now", "the steer read now waited: {lines:?}");
    q.take(lines);
    q.settle(&t).await;
    let texts: Vec<String> = q.waiting.iter().map(text_of).collect();
    assert_eq!(texts.len(), 3, "{texts:?}");
    assert!(texts[0] == "use Rust" && texts[1] == "stop now", "{texts:?}");
    assert!(texts[2].starts_with("2 messages from 2 sessions"), "{texts:?}");
}

/// Claude Code read the line before the drop reached it: that line stands, answered at its echo,
/// and the message that came goes in as the next line.
#[tokio::test]
async fn a_line_read_first_stands_and_the_new_message_goes_next() {
    let (t, mut q) = stepping().await;
    write(&t, &mut q, &from(2, "lane-a", "first")).await;
    write(&t, &mut q, &from(3, "lane-b", "second")).await;
    let read = t.inbound(&echo(&q.waiting.remove(0))).await;
    assert_eq!(answer(&read, 2).unwrap().unwrap()["stopReason"], "steered");
    let answers = q.settle(&t).await;
    assert!(answers.is_empty(), "{answers:?}");
    assert_eq!(q.waiting.len(), 1);
    assert_eq!(text_of(&q.waiting[0]), "second");
    let read = t.inbound(&echo(&q.waiting[0])).await;
    assert_eq!(answer(&read, 3).unwrap().unwrap()["stopReason"], "steered");
    assert!(answer(&read, 2).is_none(), "the first answered twice");
}

/// The X on one message of a line of several, or on one held for a line written again: nothing
/// is taken back (`withdrawn: false`), as for a message Claude Code read first, and every message
/// still goes in the one line.
#[tokio::test]
async fn a_withdraw_of_a_batched_message_takes_nothing_back() {
    let (t, mut q) = stepping().await;
    for (id, sender) in [(2, "lane-a"), (3, "lane-b")] {
        write(&t, &mut q, &from(id, sender, &format!("text {id}"))).await;
    }
    q.settle(&t).await;
    write(&t, &mut q, &from(4, "lane-c", "text 4")).await;
    for (n, prompt_id) in [(8, "p3"), (9, "p4")] {
        let withdraw = Message::request(
            n,
            method::MUX_STEER_WITHDRAW,
            json!({"sessionId": "acp-1", "promptId": prompt_id}),
        );
        let Outbound::Reply(reply) = t.outbound(&withdraw).await else {
            panic!("{prompt_id}: asked Claude Code to drop a batched message")
        };
        assert_eq!(answer(&[reply], n).unwrap().unwrap()["withdrawn"], false, "{prompt_id}");
    }
    assert!(q.settle(&t).await.is_empty());
    assert_eq!(q.waiting.len(), 1);
    let read = t.inbound(&echo(&q.waiting[0])).await;
    for id in 2..=4 {
        assert_eq!(answer(&read, id).unwrap().unwrap()["stopReason"], "steered", "{id}");
    }
}

/// The turn's result came while a line's drop was on its way (review 2 of #26707): the result
/// waits for that unread line, as for any steer; the drop goes through, and the line written in
/// its place, which Claude Code runs as one more turn, is echoed and its result ends the turn.
#[tokio::test]
async fn a_result_before_the_drop_answer_still_ends_the_turn() {
    let (t, mut q) = stepping().await;
    write(&t, &mut q, &from(2, "lane-a", "first")).await;
    write(&t, &mut q, &from(3, "lane-b", "second")).await;
    let result = json!({"type": "result", "subtype": "success", "result": "done", "num_turns": 1, "duration_api_ms": 1, "usage": {"input_tokens": 1, "output_tokens": 1}});
    let early = t.inbound(&result).await;
    assert!(answer(&early, 1).is_none(), "the turn ended with a line unread: {early:?}");
    assert!(q.settle(&t).await.is_empty());
    assert_eq!(q.waiting.len(), 1, "{:?}", q.waiting);
    assert!(text_of(&q.waiting[0]).starts_with("2 messages from 2 sessions"));
    let read = t.inbound(&echo(&q.waiting[0])).await;
    assert_eq!(answer(&read, 2).unwrap().unwrap()["stopReason"], "steered");
    assert_eq!(answer(&read, 3).unwrap().unwrap()["stopReason"], "steered");
    let ended = t.inbound(&result).await;
    assert_eq!(answer(&ended, 1).unwrap().unwrap()["stopReason"], "end_turn", "{ended:?}");
}

/// A Claude Code that cannot drop a line: the line stands, the held message goes next, and the
/// messages after it are written at once with no drop asked again.
#[tokio::test]
async fn a_refused_drop_leaves_each_line_as_it_was() {
    let (t, mut q) = stepping().await;
    write(&t, &mut q, &from(2, "lane-a", "first")).await;
    write(&t, &mut q, &from(3, "lane-b", "second")).await;
    let drop = q.drops.remove(0);
    let refused = json!({"type": "control_response", "response": {"subtype": "error", "request_id": drop["request_id"], "error": "Unsupported control request subtype: cancel_async_message"}});
    assert!(t.inbound(&refused).await.is_empty());
    q.take(t.take_stdin_replies().await);
    write(&t, &mut q, &from(4, "lane-c", "third")).await;
    assert!(q.drops.is_empty(), "asked to drop again");
    let texts: Vec<String> = q.waiting.iter().map(text_of).collect();
    assert_eq!(texts, ["first", "second", "third"]);
}

/// The answer was lost while messages were held for a drop: each held message is answered too,
/// so no send waits forever.
#[tokio::test]
async fn a_lost_answer_answers_the_held_messages_too() {
    let (t, mut q) = stepping().await;
    write(&t, &mut q, &from(2, "lane-a", "first")).await;
    write(&t, &mut q, &from(3, "lane-b", "second")).await;
    let failed = t.fail_pending("the agent's answer was too large").await;
    assert!(answer(&failed, 2).unwrap().is_err(), "{failed:?}");
    assert!(answer(&failed, 3).unwrap().is_err(), "{failed:?}");
    let answers = q.settle(&t).await;
    assert!(answers.is_empty(), "answered twice: {answers:?}");
}

/// One line is written again at a time (review 1 of #26707): with a drop on its way, a person's
/// steer goes in at once, and the next session's message waits with the held one instead of
/// asking a second drop, so the messages reach Claude Code in the order they came.
#[tokio::test]
async fn one_line_is_written_again_at_a_time() {
    let (t, mut q) = stepping().await;
    write(&t, &mut q, &from(2, "lane-a", "first")).await;
    write(&t, &mut q, &from(3, "lane-b", "second")).await;
    write(&t, &mut q, &steer(4, "use Rust", json!({"steer": true, "promptId": "p4"}))).await;
    write(&t, &mut q, &from(5, "lane-c", "third")).await;
    write(&t, &mut q, &from(6, "lane-a", "fourth")).await;
    assert_eq!(q.drops.len(), 1, "a second drop was asked: {:?}", q.drops);
    q.settle(&t).await;
    let texts: Vec<String> = q.waiting.iter().map(text_of).collect();
    assert_eq!(texts.len(), 2, "{texts:?}");
    assert_eq!(texts[0], "use Rust");
    let at = |s: &str| texts[1].find(s).unwrap_or_else(|| panic!("{s:?} missing: {}", texts[1]));
    assert!(texts[1].starts_with("4 messages from 3 sessions"), "{}", texts[1]);
    assert!(at("first") < at("second") && at("second") < at("third") && at("third") < at("fourth"));
}

/// The turn ended between `outbound`'s look and the steer's locks (review 1 of #26707): the steer
/// answers `STEER_NO_TURN`, so the hub queues it, never left waiting for an echo.
#[tokio::test]
async fn a_steer_after_the_turn_ended_answers_no_turn() {
    let (t, _) = stepping().await;
    t.in_turn.store(false, Ordering::SeqCst);
    let meta = json!({"steer": true, "promptId": "p2", "batch": {"from": "lane-a"}});
    let p = json!({"sessionId": "acp-1", "_meta": meta});
    let content = vec![json!({"type": "text", "text": "late"})];
    let Outbound::Reply(reply) = t.write_steer(&json!(2), &p, content).await else {
        panic!("a steer was written after its turn ended")
    };
    assert!(answer(&[reply], 2).unwrap().unwrap_err().starts_with(STEER_NO_TURN));
    assert!(t.steers.lock().await.is_empty());
}

/// Messages that each fit but together pass the cap (review 3 of #26707): they go in more than
/// one line, whole messages each, in order, every line under the cap, so no line nears the agent
/// host's frame limit; nothing is cut.
#[tokio::test]
async fn messages_past_the_cap_split_into_lines_of_whole_messages() {
    let (t, mut q) = stepping().await;
    let big = |i: usize| format!("{i}:{}", "x".repeat(BATCH_MAX_BYTES / 3));
    for i in 0..7 {
        write(&t, &mut q, &from(i as i64 + 2, SENDERS[i % 3], &big(i))).await;
        q.settle(&t).await;
    }
    assert!(q.waiting.len() > 1, "one line past the cap");
    let mut next = 0;
    for line in &q.waiting {
        let size = serde_json::to_string(&line["message"]["content"]).unwrap().len();
        assert!(size <= BATCH_MAX_BYTES + 4096, "a line of {size} bytes");
        let text = text_of(line);
        while next < 7 && text.contains(&big(next)) {
            next += 1;
        }
    }
    assert_eq!(next, 7, "a message is missing, cut or out of order");
    let mut answered = 0;
    for line in q.waiting.clone() {
        let read = t.inbound(&echo(&line)).await;
        answered += (2..=8).filter(|id| answer(&read, *id).is_some()).count();
    }
    assert_eq!(answered, 7);
}
