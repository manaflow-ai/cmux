//! Unit tests for the Claude stdio translator.

use super::*;

#[tokio::test]
async fn a_text_block_keeps_its_cache_control_and_drops_other_fields() {
    let t = Translator::new("acp-1".into(), "default", "haiku", "default");
    let marker = json!({"type": "ephemeral", "ttl": "1h"});
    let req = Message::request(
        9,
        method::SESSION_PROMPT,
        json!({"sessionId": "acp-1", "prompt": [
            {"type": "text", "text": "prefix", "cache_control": marker, "annotations": {"priority": 1}, "_meta": {"x": 1}},
            {"type": "text", "text": "step"},
        ]}),
    );
    let Outbound::Lines(lines) = t.outbound(&req).await else { panic!() };
    let content = lines[0]["message"]["content"].as_array().unwrap();
    // Claude Code's stream-json input copies user blocks to the API as they
    // are, so the marker reaches the Messages request unchanged.
    assert_eq!(content[0], json!({"type": "text", "text": "prefix", "cache_control": marker}));
    assert_eq!(content[1], json!({"type": "text", "text": "step"}));
}
