//! Preserve explicit Codex message phases while the pinned ACP translator omits them.
use cmux_codex_acp::Out;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Default)]
pub(super) struct MessagePhases {
    // Only sessions the translator exposes to ACP. Hidden prediction threads stay hidden.
    sessions: BTreeSet<String>,
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str).filter(|text| !text.is_empty())
}

fn phase(item: &Value) -> Option<&str> {
    if text(item, "type") != Some("agentMessage") {
        return None;
    }
    text(item, "phase").filter(|phase| matches!(*phase, "commentary" | "final_answer"))
}

impl MessagePhases {
    pub(super) fn enrich(&mut self, raw: &Value, out: &mut Vec<Out>) {
        for message in out.iter() {
            let Out::Client(message) = message else { continue };
            let session = message
                .pointer("/result/sessionId")
                .or_else(|| message.pointer("/params/sessionId"))
                .and_then(Value::as_str)
                .filter(|session| !session.is_empty());
            if let Some(session) = session.filter(|session| !self.sessions.contains(*session)) {
                self.sessions.insert(session.to_owned());
            }
            if message.pointer("/params/update/sessionUpdate").and_then(Value::as_str)
                == Some("subagent_spawned")
                && let Some(child) =
                    message.pointer("/params/update/subagentSessionId").and_then(Value::as_str)
                && !child.is_empty()
            {
                self.sessions.insert(child.to_owned());
            }
        }
        if matches!(text(raw, "method"), Some("item/started" | "item/completed")) {
            let Some(params) = raw.get("params") else { return };
            let Some(session) = text(params, "threadId").filter(|id| self.sessions.contains(*id))
            else {
                return;
            };
            let Some(item) = params.get("item") else { return };
            let (Some(id), Some(phase)) = (text(item, "id"), phase(item)) else { return };
            // Metadata-only updates annotate streamed replies without duplicating their text.
            out.push(Out::Client(json!({
                "jsonrpc": "2.0", "method": "session/update",
                "params": {"sessionId": session, "update": {
                    "sessionUpdate": "agent_message_chunk", "messageId": id,
                    "content": {"type": "text", "text": ""}, "_meta": {"codex": {"phase": phase}}
                }}
            })));
            return;
        }
        let Some(thread) = raw.pointer("/result/thread") else { return };
        let Some(session) = text(thread, "id") else { return };
        let Some(turns) = thread.get("turns").and_then(Value::as_array) else { return };
        let phases: BTreeMap<_, _> = turns
            .iter()
            .filter_map(|turn| turn.get("items").and_then(Value::as_array))
            .flatten()
            .filter_map(|item| Some((text(item, "id")?, phase(item)?)))
            .collect();
        // A resume without replay exposes no chunks, so it gains no synthetic history.
        for message in out.iter_mut() {
            let Out::Client(message) = message else { continue };
            if message.pointer("/params/sessionId").and_then(Value::as_str) != Some(session) {
                continue;
            }
            let Some(update) = message.pointer_mut("/params/update") else { continue };
            if text(update, "sessionUpdate") != Some("agent_message_chunk") {
                continue;
            }
            let Some(phase) = text(update, "messageId").and_then(|id| phases.get(id)) else {
                continue;
            };
            update["_meta"]["codex"]["phase"] = json!(phase);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exposed(phases: &mut MessagePhases) {
        phases.enrich(
            &json!({}),
            &mut vec![Out::Client(json!({"id": 1, "result": {"sessionId": "t"}}))],
        );
    }

    fn item(method: &str, thread: &str, phase: Value) -> Value {
        json!({"method": method, "params": {"threadId": thread, "item": {
            "type": "agentMessage", "id": "m", "phase": phase, "text": "The answer"
        }}})
    }

    #[test]
    fn explicit_started_and_completed_phases_emit_no_duplicate_text() {
        let mut phases = MessagePhases::default();
        exposed(&mut phases);
        for method in ["item/started", "item/completed"] {
            for phase in ["commentary", "final_answer"] {
                let mut out = Vec::new();
                phases.enrich(&item(method, "t", json!(phase)), &mut out);
                let [Out::Client(message)] = out.as_slice() else {
                    panic!("one phase update expected")
                };
                assert_eq!(message["params"]["sessionId"], "t");
                assert_eq!(message["params"]["update"]["messageId"], "m");
                assert_eq!(message["params"]["update"]["content"]["text"], "");
                assert_eq!(message["params"]["update"]["_meta"]["codex"]["phase"], phase);
            }
        }
    }

    #[test]
    fn hidden_threads_unknown_phases_and_missing_ids_emit_nothing() {
        let mut phases = MessagePhases::default();
        exposed(&mut phases);
        let mut missing = item("item/started", "t", json!("final_answer"));
        missing["params"]["item"].as_object_mut().unwrap().remove("id");
        for raw in [
            item("item/started", "hidden", json!("final_answer")),
            item("item/started", "t", json!("future")),
            item("item/started", "t", Value::Null),
            missing,
        ] {
            let mut out = Vec::new();
            phases.enrich(&raw, &mut out);
            assert!(out.is_empty());
        }
    }

    #[test]
    fn an_exposed_subagent_gets_its_phase_before_its_first_text_delta() {
        let mut phases = MessagePhases::default();
        exposed(&mut phases);
        let mut spawned = vec![Out::Client(json!({"method": "session/update", "params": {
            "sessionId": "t", "update": {"sessionUpdate": "subagent_spawned", "subagentSessionId": "child"}
        }}))];
        phases.enrich(&json!({}), &mut spawned);
        let mut out = Vec::new();
        phases.enrich(&item("item/started", "child", json!("final_answer")), &mut out);
        assert_eq!(out.len(), 1);
        let Out::Client(update) = &out[0] else { panic!("phase update expected") };
        assert_eq!(update["params"]["sessionId"], "child");
    }

    #[test]
    fn history_phases_only_annotate_actual_replayed_messages_in_the_same_session() {
        let mut phases = MessagePhases::default();
        let raw = json!({"id": 2, "result": {"thread": {"id": "t", "turns": [{"items": [
            {"type": "agentMessage", "id": "m", "phase": "final_answer"},
            {"type": "agentMessage", "id": "unknown", "phase": "future"}
        ]}]}}});
        let chunk = |session: &str, id: &str| {
            Out::Client(json!({"method": "session/update", "params": {
                "sessionId": session, "update": {"sessionUpdate": "agent_message_chunk", "messageId": id,
                    "content": {"type": "text", "text": "Answer"}}
            }}))
        };
        let mut out = vec![chunk("t", "m"), chunk("other", "m"), chunk("t", "unknown")];
        phases.enrich(&raw, &mut out);
        assert_eq!(out.len(), 3);
        let Out::Client(first) = &out[0] else { panic!("client chunk expected") };
        assert_eq!(first["params"]["update"]["_meta"]["codex"]["phase"], "final_answer");
        for other in &out[1..] {
            let Out::Client(other) = other else { panic!("client chunk expected") };
            assert!(other["params"]["update"].get("_meta").is_none());
        }
        let mut no_replay = Vec::new();
        phases.enrich(&raw, &mut no_replay);
        assert!(no_replay.is_empty());
    }
}

#[cfg(test)]
mod bridge_tests {
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
}
