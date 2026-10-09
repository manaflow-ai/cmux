//! Turns from the trace, and each turn's prompt laid out again.
//!
//! A turn's `turn.start` records the view by its parts (the tree node of
//! each line), the log ids of its messages and how the prompt was laid out.
//! Nodes and messages are never rewritten, so rendering those parts and
//! laying them out the same way gives back what the turn sent, byte for
//! byte; the trace's hashes say whether it did (`exact`).

use optchat_core::NodeId;
use optchat_host::OptChat;
use serde_json::{Value, json};

use super::Inspector;
use crate::prompt::{CMUX_INSTRUCTIONS, base_prompt};
use crate::trace::hash;

/// One turn's prompt, laid out again from the trace and the memory.
#[derive(Clone, Debug, PartialEq)]
pub struct TurnPrompt {
    /// The view the turn read (the parts' render), None when the trace has
    /// no parts and the current view is not it (a turn traced before parts).
    pub view: Option<String>,
    pub parts: Vec<NodeId>,
    /// The turn's new messages: (log id, kind, text).
    pub messages: Vec<(u64, String, String)>,
    /// The session system prompt the turn got: the system text, plus the
    /// view's head in the cached layout.
    pub system: String,
    /// The user message's content blocks, as sent (images left out).
    pub blocks: Vec<Value>,
    /// "cached" (system prompt holds the view head, one marker of ours) or
    /// "blocks" (view pieces then the messages).
    pub layout: String,
    /// Each check against the trace's hashes.
    pub view_matches: bool,
    pub system_matches: bool,
    pub messages_match: bool,
    /// Why something is missing, in plain words.
    pub note: Option<String>,
}

/// Lays out the prompt of the turn whose `turn.start` event is `start`.
pub fn turn_prompt(chat: &OptChat, start: &Value, system_text: &str) -> TurnPrompt {
    let view_ev = &start["view"];
    let mut note = None;
    let parts: Option<Vec<NodeId>> = view_ev["parts"].as_array().map(|a| {
        a.iter()
            .filter_map(|p| p.as_str().and_then(parse_name))
            .collect()
    });
    let (view, parts) = match parts {
        Some(parts) => (Some(chat.render_parts(&parts).text), parts),
        None => {
            // A turn traced before parts were recorded: only the current view
            // can stand in, and only when its hash says it is the same.
            let now = chat.render_view();
            if Some(hash(&now.text).as_str()) == view_ev["hash"].as_str() {
                (Some(now.text), now.parts)
            } else {
                note = Some("This turn ran before the trace recorded the view's parts, and the current view is different, so its view cannot be shown.".to_owned());
                (None, Vec::new())
            }
        }
    };
    let view_matches = view
        .as_deref()
        .is_some_and(|v| Some(hash(v).as_str()) == view_ev["hash"].as_str());
    let ids: Vec<u64> = start["message_ids"]
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_u64).collect())
        .unwrap_or_default();
    let messages: Vec<(u64, String, String)> = ids
        .iter()
        .filter_map(|id| {
            chat.message(*id)
                .map(|(k, t)| (*id, k.as_str().to_owned(), t))
        })
        .collect();
    let traced: Vec<&str> = start["messages"]
        .as_array()
        .map(|a| a.iter().filter_map(|m| m["hash"].as_str()).collect())
        .unwrap_or_default();
    let messages_match = !ids.is_empty()
        && messages.len() == traced.len()
        && messages.iter().zip(&traced).all(|(m, h)| hash(&m.2) == *h);
    let images = start["layout"]["images"].as_u64().unwrap_or(0);
    if images > 0 && note.is_none() {
        note = Some(format!(
            "This turn also sent {images} image block(s) before its messages; they are not shown."
        ));
    }
    if ids.is_empty() && note.is_none() {
        note = Some(
            "This turn ran before the trace recorded its message ids; its messages are not shown."
                .to_owned(),
        );
    }
    // The turn's subagents-at-work line went before its messages.
    let at_work = start["layout"]["at_work"].as_str();
    let tail = at_work
        .into_iter()
        .chain(messages.iter().map(|m| m.2.as_str()))
        .collect::<Vec<_>>()
        .join("\n\n");
    let layout = start["layout"]["kind"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| {
            if start["system"]["with_view_head"] == true {
                "cached".to_owned()
            } else {
                "blocks".to_owned()
            }
        });
    let view_text = view.as_deref().unwrap_or("");
    let (system, blocks) = if layout == "cached" {
        let marker = start["layout"]["marker"].as_bool().unwrap_or(true);
        let l = crate::prompt::cached_layout(system_text, view_text, &tail, marker);
        (l.system, l.blocks)
    } else {
        let texts: Vec<String> = messages.iter().map(|m| m.2.clone()).collect();
        (
            system_text.to_owned(),
            crate::prompt::turn_blocks(view_text, &texts),
        )
    };
    let system_matches = Some(hash(&system).as_str()) == start["system"]["hash"].as_str();
    if view.is_some() && !system_matches && note.is_none() {
        note = Some("The system prompt this host has now differs from the one the turn got (a different build, or AGENTS.md changed since).".to_owned());
    }
    TurnPrompt {
        view,
        parts,
        messages,
        system,
        blocks,
        layout,
        view_matches,
        system_matches,
        messages_match,
        note,
    }
}

/// `id+n` back to its node.
pub(crate) fn parse_name(name: &str) -> Option<NodeId> {
    let (id, n) = name.split_once('+')?;
    NodeId::from_name(id.parse().ok()?, n.parse().ok()?)
}

/// The system text cut into its named parts (prompt.rs builds it from
/// them); one part when it was built some other way.
pub fn system_parts(system_text: &str) -> Vec<Value> {
    let base = base_prompt();
    let head = format!("{base}\n\n{CMUX_INSTRUCTIONS}");
    let part = |label: &str, explain: &str, text: &str| json!({"label": label, "explain": explain, "text": text, "bytes": text.len()});
    let Some(rest) = system_text.strip_prefix(&head) else {
        return vec![part(
            "System prompt",
            "The instructions every turn starts with.",
            system_text,
        )];
    };
    let mut out = vec![
        part(
            "The spec's prompt",
            "Taelin's one prompt for turns and compactions: the view, turns, compactions.",
            &base,
        ),
        part(
            "cmux instructions",
            "How Chief works inside cmux: tools, subagents, engine.",
            CMUX_INSTRUCTIONS,
        ),
    ];
    let user = rest.trim_matches('\n');
    if !user.is_empty() {
        out.push(part(
            "Your instructions (AGENTS.md)",
            "Your own file, optchat/AGENTS.md, read when the host starts.",
            user,
        ));
    }
    out
}

/// The view's lines with the node each came from and where it sits.
pub(crate) fn view_lines(chat: &OptChat, view: &str, parts: &[NodeId]) -> Vec<Value> {
    let mut offset = "<chat>\n".len();
    let mut lines = Vec::with_capacity(parts.len());
    for (part, line) in parts.iter().zip(view.split('\n').skip(1)) {
        let built = chat.node(*part).is_some();
        lines.push(json!({
            "name": part.name(),
            "level": part.l,
            "start": part.start(),
            "n": part.n(),
            "offset": offset,
            "bytes": line.len() + 1,
            "built": built,
            "text": line.split_once('|').map_or(line, |(_, t)| t),
        }));
        offset += line.len() + 1;
    }
    lines
}

/// The blocks as the inspector draws them: where each sits and whether it
/// carries our cache marker.
fn block_map(prompt: &TurnPrompt, system_text: &str) -> Vec<Value> {
    let mut out = vec![json!({
        "role": "system",
        "kind": "instructions",
        "bytes": system_text.len(),
        "cache": "harness",
    })];
    let head = prompt.system.len().saturating_sub(system_text.len());
    if head > 2 {
        out.push(json!({"role": "system", "kind": "view", "view_start": 0, "bytes": head - 2, "cache": "harness"}));
    }
    let mut at = head.saturating_sub(2);
    let last = prompt.blocks.len().saturating_sub(1);
    for (k, b) in prompt.blocks.iter().enumerate() {
        let text = b["text"].as_str().unwrap_or("");
        let marker = b.get("cache_control").is_some();
        if k == last {
            out.push(json!({"role": "user", "kind": "messages", "bytes": text.len(), "cache": "harness"}));
        } else {
            out.push(json!({"role": "user", "kind": "view", "view_start": at, "bytes": text.len(), "cache": if marker { "ours" } else { "none" }}));
            at += text.len();
        }
    }
    out
}

/// The `/api/turn` answer for a laid-out prompt.
pub(crate) fn prompt_json(prompt: &TurnPrompt, start: &Value) -> Value {
    json!({
        "turn": start["turn"],
        "ts": start["ts"],
        "harness": start["harness"],
        "model": start["model"],
        "layout": prompt.layout,
        "exact": {
            "view": prompt.view_matches,
            "system": prompt.system_matches,
            "messages": prompt.messages_match,
        },
        "note": prompt.note,
        "view": prompt.view.as_ref().map(|v| json!({
            "text": v,
            "bytes": v.len(),
            "marks": optchat_core::cache_marks(v),
            "grid": optchat_core::block_cuts(v),
            "unchanged_prefix_bytes": start["view"]["unchanged_prefix_bytes"],
            "parts": prompt.parts.iter().map(|p| p.name()).collect::<Vec<_>>(),
        })),
        "messages": prompt.messages.iter().map(|(id, kind, text)| json!({"id": id, "kind": kind, "text": text})).collect::<Vec<_>>(),
        "system": {"bytes": prompt.system.len()},
        "blocks_sent": prompt.blocks.len(),
    })
}

/// `/api/turn?key=now`: the view the next turn would read now, in the
/// cached layout, with no new messages yet.
pub(crate) fn current(inspector: &Inspector) -> Value {
    let view = inspector.chat.render_view();
    let layout = crate::prompt::cached_layout(&inspector.system_text, &view.text, "", true);
    let prompt = TurnPrompt {
        view: Some(view.text),
        parts: view.parts,
        messages: Vec::new(),
        system: layout.system,
        blocks: layout.blocks,
        layout: "cached".to_owned(),
        view_matches: true,
        system_matches: true,
        messages_match: true,
        note: Some(
            "The view as it stands now: the next turn reads it, then its new messages. Shown in \
             the cached layout with its marker (a Claude harness); a Codex turn sends the view \
             as plain blocks."
                .to_owned(),
        ),
    };
    let mut out = prompt_json(&prompt, &json!({"turn": "now", "view": {}}));
    inspector.decorate(&mut out, &prompt);
    out
}

impl Inspector {
    /// Lines, system parts and block map for a turn's answer.
    pub(crate) fn decorate(&self, out: &mut Value, prompt: &TurnPrompt) {
        if let Some(view) = &prompt.view {
            out["lines"] = json!(view_lines(&self.chat, view, &prompt.parts));
        }
        out["system_parts"] = json!(system_parts(&self.system_text));
        out["blocks"] = json!(block_map(prompt, &self.system_text));
    }
}

/// One row per turn, oldest first: what the timeline draws.
pub fn summaries(events: &[Value]) -> Vec<Value> {
    let mut rows: Vec<Value> = Vec::new();
    let mut index: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let mut nodes_since_turn = 0u64;
    let mut node_ms_since_turn = 0u64;
    let mut open: Option<usize> = None;
    for e in events {
        let ev = e["ev"].as_str().unwrap_or("");
        let key = e["turn"].as_str().map(str::to_owned);
        match ev {
            "turn.start" => {
                let Some(key) = key else { continue };
                let row = json!({
                    "turn": key,
                    "first": e["first"],
                    "ts": e["ts"],
                    "engine": e["engine"],
                    "harness": e["harness"],
                    "model": e["model"],
                    "effort": e["effort"],
                    "settle_ms": e["settle_ms"],
                    "view_bytes": e["view"]["bytes"],
                    "view_lines": e["view"]["lines"],
                    "unchanged_prefix_bytes": e["view"]["unchanged_prefix_bytes"],
                    "parts_recorded": e["view"]["parts_recorded"].as_bool().unwrap_or(false),
                    "sources": e["sources"],
                    "messages": e["messages"].as_array().map_or(0, Vec::len),
                    "nodes_before": nodes_since_turn,
                    "nodes_before_ms": node_ms_since_turn,
                    "nodes_during": 0,
                    "tool_names": {},
                    "status": Value::Null,
                });
                nodes_since_turn = 0;
                node_ms_since_turn = 0;
                index.insert(key, rows.len());
                open = Some(rows.len());
                rows.push(row);
            }
            "turn.end" => {
                let Some(&k) = key.as_ref().and_then(|k| index.get(k)) else {
                    continue;
                };
                let r = &mut rows[k];
                for f in [
                    "ms",
                    "status",
                    "first_usage",
                    "usage",
                    "cost_usd",
                    "requests",
                    "tools",
                    "tool_errors",
                    "harness_kind",
                    "harness_profile",
                ] {
                    r[f] = e[f].clone();
                }
                r["error"] = e["error"]["prefix"].clone();
                r["hit_rate"] = json!(crate::report::hit_rate(&e["first_usage"]));
                if open == Some(k) {
                    open = None;
                }
            }
            "tool" => {
                let Some(&k) = key.as_ref().and_then(|k| index.get(k)) else {
                    continue;
                };
                let name = e["name"].as_str().unwrap_or("?").to_owned();
                let names = &mut rows[k]["tool_names"];
                names[&name] = json!(names[&name].as_u64().unwrap_or(0) + 1);
            }
            "node" => match open {
                Some(k) => {
                    rows[k]["nodes_during"] =
                        json!(rows[k]["nodes_during"].as_u64().unwrap_or(0) + 1);
                }
                None => {
                    nodes_since_turn += 1;
                    node_ms_since_turn += e["ms"].as_u64().unwrap_or(0);
                }
            },
            _ => {}
        }
    }
    rows
}
