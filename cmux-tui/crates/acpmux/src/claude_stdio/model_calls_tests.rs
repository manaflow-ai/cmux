//! `model_calls.rs`: a call's timing.

use super::model_calls::ModelClock;
use serde_json::json;

#[test]
fn a_call_spans_its_request_to_its_last_token() {
    let clock = ModelClock::default();
    clock.requested(1_000);
    clock.started(3_100);
    clock.thought();
    let timing = clock.ended(4_900).unwrap();
    assert_eq!(
        timing,
        json!({"requestAt": 1_000, "firstTokenAt": 3_100, "lastTokenAt": 4_900, "thought": true})
    );
}

#[test]
fn the_latest_request_before_the_first_byte_is_the_calls() {
    let clock = ModelClock::default();
    clock.requested(1_000);
    // The prompt's echo, then two tool results: the request went out after the last.
    clock.requested(1_200);
    clock.requested(1_500);
    clock.started(2_000);
    assert_eq!(clock.ended(2_500).unwrap()["requestAt"], 1_500);
}

#[test]
fn a_call_with_no_request_since_the_last_went_out_when_that_one_ended() {
    let clock = ModelClock::default();
    clock.requested(1_000);
    clock.started(1_400);
    clock.ended(2_000).unwrap();
    clock.started(2_600);
    let timing = clock.ended(3_000).unwrap();
    assert_eq!(timing["requestAt"], 2_000);
    assert!(timing.get("thought").is_none());
}

#[test]
fn usage_without_a_seen_start_is_not_timed() {
    let clock = ModelClock::default();
    clock.requested(1_000);
    assert!(clock.ended(2_000).is_none());
    // Timed once: a second usage of the same call carries none.
    clock.started(2_100);
    assert!(clock.ended(2_400).is_some());
    assert!(clock.ended(2_500).is_none());
}

#[test]
fn a_request_clears_a_call_that_was_cut_off() {
    let clock = ModelClock::default();
    clock.requested(1_000);
    clock.started(1_500);
    clock.thought();
    // Stopped before its usage; the next prompt goes out.
    clock.requested(9_000);
    clock.started(9_800);
    let timing = clock.ended(10_000).unwrap();
    assert_eq!(timing["requestAt"], 9_000);
    assert!(timing.get("thought").is_none());
}

#[test]
fn thinking_outside_a_call_marks_nothing() {
    let clock = ModelClock::default();
    clock.thought();
    clock.requested(1_000);
    clock.started(1_100);
    assert!(clock.ended(1_200).unwrap().get("thought").is_none());
}

/// The `_meta.acpmux.timing` of each `usage_update` the messages carry.
fn timings(msgs: &[crate::rpc::Message]) -> Vec<Option<serde_json::Value>> {
    msgs.iter()
        .filter_map(|m| match m {
            crate::rpc::Message::Notification { params, .. } => {
                let update = params.as_ref()?.get("update")?;
                (update.get("sessionUpdate")? == "usage_update")
                    .then(|| update.pointer("/_meta/acpmux/timing").cloned())
            }
            _ => None,
        })
        .collect()
}

/// Claude Code 2.1.310's lines for one turn of two calls: the prompt goes out, the first call
/// thinks (its thinking in one late burst) and calls a tool, the tool's result goes out, the second
/// call answers. Each call's usage carries when it went out and came back, on the daemon's clock.
#[tokio::test]
async fn each_main_call_is_timed_from_its_request_to_its_last_token() {
    use super::Translator;
    use super::prompt_cache::now_ms;
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let usage = json!({"input_tokens": 2, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 30});
    let before = now_ms();
    t.inbound(&json!({"type": "user", "isReplay": true, "uuid": "u-1", "message": {"role": "user", "content": "hi"}})).await;
    t.inbound(&json!({"type": "stream_event", "event": {"type": "message_start", "message": {"id": "m1", "model": "claude-opus-5-5", "usage": usage}}})).await;
    t.inbound(&json!({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "thinking_delta", "thinking": "Queue both"}}})).await;
    let first = t
        .inbound(
            &json!({"type": "stream_event", "event": {"type": "message_delta", "usage": usage}}),
        )
        .await;
    let between = now_ms();
    t.inbound(&json!({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"}]}})).await;
    t.inbound(&json!({"type": "stream_event", "event": {"type": "message_start", "message": {"id": "m2", "model": "claude-opus-5-5", "usage": usage}}})).await;
    let second = t
        .inbound(
            &json!({"type": "stream_event", "event": {"type": "message_delta", "usage": usage}}),
        )
        .await;
    let after = now_ms();

    let [Some(one)] = &timings(&first)[..] else { panic!("{first:?}") };
    let (request, first_token, last_token) = (
        one["requestAt"].as_u64().unwrap(),
        one["firstTokenAt"].as_u64().unwrap(),
        one["lastTokenAt"].as_u64().unwrap(),
    );
    assert!(
        before <= request
            && request <= first_token
            && first_token <= last_token
            && last_token <= between,
        "{one}"
    );
    assert_eq!(one["thought"], true);

    let [Some(two)] = &timings(&second)[..] else { panic!("{second:?}") };
    let request = two["requestAt"].as_u64().unwrap();
    assert!(
        between <= request
            && request <= two["lastTokenAt"].as_u64().unwrap()
            && two["lastTokenAt"].as_u64().unwrap() <= after,
        "{two}"
    );
    assert!(two.get("thought").is_none(), "the second call streamed no thinking: {two}");
}

/// A subagent's calls are its own stream: they carry no timing and leave the chat's call alone.
#[tokio::test]
async fn a_subagents_call_is_not_timed() {
    use super::Translator;
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let usage = json!({"input_tokens": 2, "output_tokens": 9});
    t.inbound(&json!({"type": "stream_event", "parent_tool_use_id": "toolu_1", "event": {"type": "message_start", "message": {"id": "s1", "usage": usage}}})).await;
    let msgs = t.inbound(&json!({"type": "stream_event", "parent_tool_use_id": "toolu_1", "event": {"type": "message_delta", "usage": usage}})).await;
    assert!(timings(&msgs).iter().all(Option::is_none), "{msgs:?}");
}
