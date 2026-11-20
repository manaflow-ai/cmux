use super::*;

/// The replies as `last` read them before it stopped early: the transcript of every record
/// read, its last `count` replies.
fn replies_reference(events: &[Value], count: usize) -> Vec<String> {
    let mut t = Transcript::default();
    for e in events {
        t.apply_event(e);
    }
    let mut out: Vec<String> = t
        .items
        .iter()
        .rev()
        .filter_map(|i| match i {
            Item::Assistant { text } => Some(text.clone()),
            _ => None,
        })
        .take(count.max(1))
        .collect();
    out.reverse();
    out
}

fn update(seq: u64, update: Value) -> Value {
    json!({"seq": seq, "at": seq, "dir": "in", "kind": "session_update",
        "msg": {"method": "session/update", "params": {"sessionId": "s", "update": update}}})
}

fn text(kind: &str, text: &str) -> Value {
    json!({"sessionUpdate": kind, "content": {"type": "text", "text": text}})
}

fn mux(seq: u64, kind: &str, msg: Value) -> Value {
    json!({"seq": seq, "at": seq, "dir": "mux", "kind": kind, "msg": msg})
}

/// A log of `len` transcript records drawn from `seed`: replies, thoughts and user words in
/// chunks, tool calls and their updates, plans, the person's messages (queued ones too, and
/// steers), permissions, and turn ends. Ids and texts come from small sets, so records often
/// change items far back.
fn log(seed: u64, len: u64) -> Vec<Value> {
    let mut state = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
    let mut next = || {
        state =
            state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        state >> 33
    };
    (1..=len)
        .map(|seq| {
            let words = format!("w{seq} ");
            let call = format!("call-{}", next() % 4);
            let said = format!("message {}", next() % 3);
            let perm = format!("perm-{}", next() % 3);
            let u = match next() % 20 {
                0..=7 => text("agent_message_chunk", &words),
                8 => text("agent_thought_chunk", &words),
                9 => text("user_message_chunk", &words),
                10 => json!({"sessionUpdate": "tool_call", "toolCallId": call, "title": words,
                    "kind": "execute", "status": "pending"}),
                11 => json!({"sessionUpdate": "tool_call_update", "toolCallId": call,
                    "status": "completed"}),
                12 => json!({"sessionUpdate": "plan", "entries": [{"content": words, "status": "pending"}]}),
                13 => return mux(seq, "turn_end", json!({"stopReason": "end_turn"})),
                14 => return mux(seq, "queued", json!({"text": said})),
                15 => {
                    let steer = next() % 3 == 0;
                    let prompt = format!("p{}", next() % 3);
                    return mux(
                        seq,
                        "user_message",
                        json!({"text": said, "steer": steer, "promptId": prompt}),
                    );
                }
                16 => {
                    return mux(seq, "permission_request", json!({"permissionId": perm,
                        "request": {"toolCall": {"title": words}, "options": []}}));
                }
                17 => {
                    return mux(seq, "permission_auto", json!({"permissionId": perm,
                        "optionId": "allow", "request": {"toolCall": {"title": words}}}));
                }
                18 => return mux(seq, "permission_decision", json!({"permissionId": perm, "optionId": "allow"})),
                _ => return mux(seq, "turn_result", json!({"stopReason": "end_turn"})),
            };
            update(seq, u)
        })
        .collect()
}

/// Whenever the newest records alone say their replies are whole, those replies are the ones
/// the whole log gives: for every log, every count and every point the read could stop at.
#[test]
fn replies_said_whole_are_the_replies_of_the_whole_log() {
    let mut stopped_early = 0;
    for seed in 0..500 {
        let events = log(seed, 80);
        for count in 1..=3 {
            let want = replies_reference(&events, count);
            assert_eq!(replies(&events, count).0, want, "seed {seed} count {count}");
            for start in 0..events.len() {
                let (got, whole) = replies(&events[start..], count);
                if whole {
                    stopped_early += usize::from(start > 0);
                    assert_eq!(got, want, "seed {seed} count {count} from record {start}");
                }
            }
        }
    }
    assert!(stopped_early > 1000, "the read stops early in common logs ({stopped_early})");
}

/// A reply whose first chunk is not among the records read is never whole, nor one without an
/// item before it.
#[test]
fn a_reply_cut_at_the_start_of_the_records_read_is_not_whole() {
    let events = vec![
        update(1, text("user_message_chunk", "the prompt")),
        update(2, text("agent_message_chunk", "the ")),
        update(3, text("agent_message_chunk", "reply")),
    ];
    assert_eq!(replies(&events, 1), (vec!["the reply".to_owned()], true));
    assert_eq!(replies(&events[1..], 1), (vec!["the reply".to_owned()], false));
    assert_eq!(replies(&events[2..], 1), (vec!["reply".to_owned()], false));
    // Two asked for, one there: never whole, so the read goes on to the start of the log.
    assert_eq!(replies(&events, 2), (vec!["the reply".to_owned()], false));
    assert_eq!(replies(&[], 1), (Vec::new(), false));
}

/// A tool update whose call is older than the records read adds an item here but changes the
/// older one in the whole log, where the reply goes on across it: the reply is not whole.
#[test]
fn a_reply_that_an_older_tool_call_may_join_is_not_whole() {
    let events = vec![
        update(1, json!({"sessionUpdate": "tool_call", "toolCallId": "c", "title": "ls"})),
        update(2, text("user_message_chunk", "the prompt")),
        update(3, text("agent_message_chunk", "the ")),
        update(
            4,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "c", "status": "completed"}),
        ),
        update(5, text("agent_message_chunk", "reply")),
    ];
    assert_eq!(replies(&events, 1), (vec!["the reply".to_owned()], true));
    assert_eq!(replies(&events[1..], 1), (vec!["reply".to_owned()], false));
    // A call made among the records read is updated in place in both: whole.
    let events = vec![
        update(1, text("user_message_chunk", "the prompt")),
        update(2, json!({"sessionUpdate": "tool_call", "toolCallId": "c", "title": "ls"})),
        update(3, text("agent_message_chunk", "the ")),
        update(
            4,
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "c", "status": "completed"}),
        ),
        update(5, text("agent_message_chunk", "reply")),
    ];
    assert_eq!(replies(&events, 1), (vec!["the reply".to_owned()], true));
}
