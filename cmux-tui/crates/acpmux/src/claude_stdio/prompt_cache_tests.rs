//! The chat's prompt cache expiry (`prompt_cache.rs`): from the main loop's last request and the
//! tier its usage names, sent on its `usage_update`s. Lines as Claude Code 2.1.310 streams them.

use super::*;
use crate::rpc::Message;

fn expiries(msgs: &[Message]) -> Vec<Option<u64>> {
    msgs.iter()
        .filter_map(|m| match m {
            Message::Notification { params, .. } => {
                let update = params.as_ref()?.get("update")?;
                (update.get("sessionUpdate")? == "usage_update")
                    .then(|| update.pointer("/_meta/acpmux/cacheExpiresAt").and_then(Value::as_u64))
            }
            _ => None,
        })
        .collect()
}

fn usage(read: u64, write_5m: u64, write_1h: u64) -> Value {
    json!({
        "input_tokens": 2,
        "cache_read_input_tokens": read,
        "cache_creation_input_tokens": write_5m + write_1h,
        "cache_creation": {"ephemeral_5m_input_tokens": write_5m, "ephemeral_1h_input_tokens": write_1h},
        "output_tokens": 30,
    })
}

/// One main-loop call: its start (with `start_usage`), then its usage. Returns the delta's
/// messages and the time before its start.
async fn call(t: &Translator, start_usage: Value, delta_usage: Value) -> (Vec<Message>, u64) {
    let before = now_ms();
    t.inbound(&json!({"type": "stream_event", "event": {"type": "message_start", "message": {"id": "m", "model": "claude-opus-5-5", "usage": start_usage}}})).await;
    let msgs = t
        .inbound(&json!({"type": "stream_event", "event": {"type": "message_delta", "usage": delta_usage}}))
        .await;
    (msgs, before)
}

#[test]
fn the_tier_comes_from_the_calls_writes() {
    assert_eq!(reported_ttl_ms(&usage(100, 10, 0)), Some(FIVE_MINUTES_MS));
    assert_eq!(reported_ttl_ms(&usage(100, 0, 10)), Some(ONE_HOUR_MS));
    assert_eq!(reported_ttl_ms(&usage(100, 0, 0)), None, "a read-only call names no tier");
    assert_eq!(reported_ttl_ms(&json!({"cache_creation_input_tokens": 10})), None);
}

#[test]
fn expiry_is_the_request_time_plus_the_ttl() {
    assert_eq!(expires_at_ms(1_000, Some(FIVE_MINUTES_MS), 5), Some(1_000 + FIVE_MINUTES_MS));
    assert_eq!(expires_at_ms(1_000, Some(FIVE_MINUTES_MS), 0), None, "no cache used");
    assert_eq!(expires_at_ms(1_000, None, 5), None, "unknown TTL");
    assert_eq!(expires_at_ms(0, Some(FIVE_MINUTES_MS), 5), None, "no request seen");
}

#[tokio::test]
async fn a_main_call_sends_its_cache_expiry_from_its_start() {
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let (msgs, before) = call(&t, usage(0, 0, 0), usage(300_000, 500, 0)).await;
    let [Some(at)] = expiries(&msgs)[..] else { panic!("{msgs:?}") };
    assert!((before + FIVE_MINUTES_MS..=now_ms() + FIVE_MINUTES_MS).contains(&at), "{at}");
    // A later read-only call keeps the 1 hour tier an earlier call named.
    call(&t, usage(0, 0, 0), usage(300_000, 0, 800)).await;
    let (msgs, before) = call(&t, usage(0, 0, 0), usage(300_800, 0, 0)).await;
    let [Some(at)] = expiries(&msgs)[..] else { panic!("{msgs:?}") };
    assert!(at >= before + ONE_HOUR_MS, "{at}");
}

#[tokio::test]
async fn the_turns_result_carries_the_expiry_and_a_compaction_clears_it() {
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let (msgs, _) = call(&t, usage(0, 400, 0), usage(9_000, 400, 0)).await;
    let [Some(at)] = expiries(&msgs)[..] else { panic!("{msgs:?}") };
    let result = json!({"type": "result", "subtype": "success", "result": "ok", "num_turns": 1, "modelUsage": {"claude-opus-5-5": {"contextWindow": 400000}}});
    let msgs = t.inbound(&result).await;
    assert_eq!(expiries(&msgs), [Some(at)], "{msgs:?}");
    t.inbound(&json!({"type": "system", "subtype": "compact_boundary", "compact_metadata": {"trigger": "manual", "pre_tokens": 9400, "post_tokens": 900}})).await;
    let msgs = t.inbound(&result).await;
    assert!(
        expiries(&msgs).iter().all(Option::is_none),
        "a compacted context has no warm cache: {msgs:?}"
    );
}

#[tokio::test]
async fn no_expiry_without_cache_use_a_known_ttl_or_for_a_subagent() {
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let (msgs, _) = call(&t, json!({}), json!({"input_tokens": 50, "output_tokens": 3})).await;
    assert_eq!(expiries(&msgs), [None], "caching off");
    let no_tier = json!({"input_tokens": 2, "cache_read_input_tokens": 900, "output_tokens": 3});
    let (msgs, _) = call(&t, json!({}), no_tier).await;
    assert_eq!(expiries(&msgs), [None], "no call has named a tier");
    // A subagent's call is its own cache.
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    t.inbound(&json!({"type": "stream_event", "parent_tool_use_id": "toolu_1", "event": {"type": "message_start", "message": {"id": "s", "usage": usage(0, 9, 0)}}})).await;
    let msgs = t.inbound(&json!({"type": "stream_event", "parent_tool_use_id": "toolu_1", "event": {"type": "message_delta", "usage": usage(100, 9, 0)}})).await;
    assert!(expiries(&msgs).iter().all(Option::is_none), "{msgs:?}");
}

#[tokio::test]
async fn a_call_stopped_before_its_delta_still_moves_the_expiry() {
    let t = Translator::new("acp-1".into(), "default", "opus", "default");
    let (msgs, _) = call(&t, usage(0, 400, 0), usage(9_000, 400, 0)).await;
    let [Some(first)] = expiries(&msgs)[..] else { panic!("{msgs:?}") };
    std::thread::sleep(std::time::Duration::from_millis(5));
    // Stopped mid-call: its start named the cache it read, and no delta came.
    t.inbound(&json!({"type": "stream_event", "event": {"type": "message_start", "message": {"id": "m2", "usage": usage(9_400, 0, 0)}}})).await;
    let result = json!({"type": "result", "subtype": "success", "result": "ok", "num_turns": 1, "modelUsage": {"claude-opus-5-5": {"contextWindow": 400000}}});
    let [Some(at)] = expiries(&t.inbound(&result).await)[..] else { panic!() };
    assert!(at > first, "{at} after {first}");
}
