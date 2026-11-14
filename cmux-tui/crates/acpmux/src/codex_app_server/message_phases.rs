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
mod tests;

#[cfg(test)]
mod bridge_tests;
