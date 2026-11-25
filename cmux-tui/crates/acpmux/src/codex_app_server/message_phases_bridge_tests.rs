use crate::codex_app_server::{split, translator_with};
use serde_json::{Value, json};

#[test]
fn message_phases_reach_acp_through_the_real_translator_without_repeating_deltas() {
    let tr = translator_with(false);
    let init = split(tr.start()).server[0]["id"].clone();
    let list =
        split(tr.from_server(&json!({"id": init, "result": {"userAgent": "acpmux/0.164.0"}})));
    let list = list.server.iter().find(|m| m["method"] == "model/list").unwrap()["id"].clone();
    tr.from_server(&json!({"id": list, "result": {"data": []}}));
    let new = split(tr.from_client(
        &json!({"id": 1, "method": "session/new", "params": {"cwd": "/tmp", "mcpServers": []}}),
    ));
    let new = new.server.iter().find(|m| m["method"] == "thread/start").unwrap()["id"].clone();
    tr.from_server(&json!({"id": new, "result": {"thread": {"id": "t"}}}));
    let mut messages = Vec::new();
    for method in ["item/started", "item/agentMessage/delta", "item/completed"] {
        let params = if method.ends_with("/delta") {
            json!({"threadId": "t", "itemId": "m", "delta": "The answer"})
        } else {
            json!({"threadId": "t", "item": {"type": "agentMessage", "id": "m", "phase": "final_answer", "text": "The answer"}})
        };
        messages.extend(
            split(tr.from_server(&json!({"method": method, "params": params})))
                .hub
                .into_iter()
                .map(|message| message.to_value()),
        );
    }
    let updates: Vec<&Value> = messages
        .iter()
        .filter_map(|message| message.pointer("/params/update"))
        .filter(|update| update["sessionUpdate"] == "agent_message_chunk")
        .collect();
    assert_eq!(
        updates
            .iter()
            .filter_map(|update| update.pointer("/content/text").and_then(Value::as_str))
            .collect::<String>(),
        "The answer"
    );
    assert_eq!(
        updates
            .iter()
            .filter(|update| update.pointer("/_meta/codex/phase").and_then(Value::as_str)
                == Some("final_answer"))
            .count(),
        2
    );
    assert!(updates.iter().all(|update| update["messageId"] == "m"));
}
