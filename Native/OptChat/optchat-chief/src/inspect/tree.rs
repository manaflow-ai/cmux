//! The memory tree for a person: one node with its two children (what the
//! agent's `zoom` shows), and one level of the tree a page at a time.

use optchat_core::NodeId;
use serde_json::{Value, json};

use super::turns::parse_name;
use super::{Answer, Inspector, bad, not_found, parse_or};

/// Characters of a node's text in a level listing.
const PREVIEW: usize = 160;

impl Inspector {
    fn node_brief(&self, node: NodeId) -> Value {
        let text = self.chat.node(node);
        json!({
            "name": node.name(),
            "level": node.l,
            "start": node.start(),
            "n": node.n(),
            "built": text.is_some(),
            "bytes": text.as_ref().map(String::len),
            "text": text,
        })
    }

    /// `/api/node?name=id+n`: the node, its children (the two lines
    /// `zoom(id, n)` answers) or, for one message, the message whole; the
    /// agent's own `zoom` answer, its dates, and whether the view shows it.
    pub(super) fn node(&self, name: &str) -> Answer {
        let node = parse_name(name).ok_or_else(|| {
            bad(format!(
                "{name:?} is not a node name: id+n, n a power of two, id a multiple of n"
            ))
        })?;
        let t = self.chat.status().messages;
        if node.checked_end().is_none_or(|end| end > t) {
            return Err(not_found(format!("No line {name}.")));
        }
        let mut out = self.node_brief(node);
        out["end"] = json!(node.end());
        out["date_first"] = json!(self.chat.date(node.start()));
        out["date_last"] = json!(self.chat.date(node.end() - 1));
        out["parent"] = json!(
            (node.parent().checked_end().is_some_and(|e| e <= t)).then(|| node.parent().name())
        );
        out["in_view"] = json!(self.chat.render_view().parts.contains(&node));
        out["zoom"] = json!({
            "call": format!("zoom({}, {})", node.start(), node.n()),
            "answer": self.chat.zoom(node.start(), node.n()).unwrap_or_else(|e| e.to_string()),
        });
        match node.children() {
            Some((a, b)) => {
                out["children"] = json!([self.node_brief(a), self.node_brief(b)]);
            }
            None => {
                let message = self.chat.message(node.start()).map(|(kind, text)| {
                    json!({"id": node.start(), "kind": kind.as_str(), "text": text, "bytes": text.len()})
                });
                out["message"] = json!(message);
            }
        }
        Ok(out)
    }

    /// `/api/level?l=L&from=I&limit=K`: nodes `I..I+K` of level `L` (each
    /// covers 2^L messages), with a preview of each text. `from` defaults to
    /// the last page, the newest nodes.
    pub(super) fn level(&self, l: Option<&str>, from: Option<&str>, limit: Option<&str>) -> Answer {
        let l: u32 = parse_or(l, 0)?;
        if l > 62 {
            return Err(bad("level must be below 63"));
        }
        let limit: u64 = parse_or(limit, 100u64)?.clamp(1, 500);
        let t = self.chat.status().messages;
        let count = t >> l;
        let from: u64 = parse_or(from, count.saturating_sub(limit))?.min(count);
        let nodes: Vec<Value> = (from..count.min(from + limit))
            .map(|i| {
                let node = NodeId::new(l, i);
                let mut brief = self.node_brief(node);
                if let Some(text) = brief["text"].as_str() {
                    let preview: String = text.chars().take(PREVIEW).collect();
                    brief["text"] = json!(preview.replace('\n', " "));
                }
                brief
            })
            .collect();
        Ok(json!({
            "level": l,
            "per_node": 1u64 << l,
            "count": count,
            "from": from,
            "nodes": nodes,
        }))
    }
}
