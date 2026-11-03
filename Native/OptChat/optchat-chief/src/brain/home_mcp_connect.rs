//! A hidden subagent's MCP connect card in Home (plans/cmux-next/mcp-connect-DESIGN.md, step 3b).
//! acpmux tells the host when a card opens and closes (`_acpmux/mcp_connect_pending`). The card
//! rides on the Home approval path (`home_approvals.rs`) as a permission-shaped request whose id
//! starts with [`MCP_CONNECT`]: Connect and Don't connect, with the exact address, publisher,
//! sign-in kind and scope in its preview. Only the person's app answers it
//! (`_acpmux/mcp_connect_answer`, with the person's proof); the host never does, and keeps no
//! deadline for it (acpmux closes an unanswered card itself).
use super::{Brain, Source};
use serde_json::{Value, json};

/// The id prefix of a connect card's pending request (`mcp-connect:<requestId>`).
pub(crate) const MCP_CONNECT: &str = "mcp-connect:";

/// Whether a pending request is a connect card, not an agent's tool permission.
pub(crate) fn is_mcp_connect(permission_id: &str) -> bool {
    permission_id.starts_with(MCP_CONNECT)
}

/// The Home card's request for acpmux's card: the facts the person decides on and the two
/// one-shot answers. The scope is the agent's proposal; the person's app sends it back.
pub(crate) fn connect_request(card: &Value) -> Option<Value> {
    let request_id = card.get("requestId")?.as_str()?;
    let title = card
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or("an MCP server");
    let scope = card
        .get("proposedScope")
        .and_then(Value::as_str)
        .unwrap_or("chat");
    let address = card
        .get("url")
        .cloned()
        .or_else(|| card.get("argv").cloned())
        .unwrap_or(Value::Null);
    Some(json!({
        "toolCall": {
            "title": format!("Connect the MCP server {title}"),
            "kind": "other",
            "rawInput": {
                "server": address,
                "publisher": card.get("publisher").cloned().unwrap_or(Value::Null),
                "verified": card.get("verified").cloned().unwrap_or(Value::Bool(false)),
                "signIn": card.get("auth").cloned().unwrap_or(Value::Null),
                "scope": scope,
                "reason": card.get("reason").cloned().unwrap_or(Value::Null),
            },
            "_meta": {"acpmux": {"mcpConnect": {"requestId": request_id, "scope": scope}}},
        },
        "options": [
            {"optionId": "allow", "name": "Connect", "kind": "allow_once"},
            {"optionId": "deny", "name": "Don't connect", "kind": "reject_once"},
        ],
    }))
}

impl Brain {
    /// acpmux opened (`mcp_connect_request`) or closed (`mcp_connect_decision`) a connect card
    /// in `session_id`. A subagent's card shows in Home as long as it is open.
    pub(super) fn sub_mcp_connect(&mut self, session_id: &str, kind: &str, card: &Value) {
        let Some(id) = self.state.sub_by_session(session_id) else {
            return;
        };
        let Some(request_id) = card.get("requestId").and_then(Value::as_str) else {
            return;
        };
        let permission_id = format!("{MCP_CONNECT}{request_id}");
        let current = self
            .state
            .sub(&id)
            .and_then(|(_, s)| s.permission.as_ref())
            .map(|p| p.id.clone());
        if kind == "mcp_connect_decision" {
            if current.as_deref() == Some(permission_id.as_str()) {
                self.end_home_approval(&id, true);
                if let Some(sub) = self.state.sub_mut(&id) {
                    sub.permission = None;
                }
                self.save();
                self.flush_outbox();
            }
            return;
        }
        if kind != "mcp_connect_request" {
            return;
        }
        let Some(request) = connect_request(card) else {
            return;
        };
        if current.as_deref() == Some(permission_id.as_str()) {
            return;
        }
        // One prompt at a time: a newer card replaces an older connect card, never a tool
        // permission the subagent still waits on (that one keeps its own card).
        if current.as_deref().is_some_and(|p| !is_mcp_connect(p)) {
            return;
        }
        self.cancel_home_approval(&id);
        if let Some(sub) = self.state.sub_mut(&id) {
            sub.permission = Some(crate::state::PendingPermission {
                id: permission_id,
                request,
                home_message: None,
                home_closed: false,
            });
        }
        self.save();
        self.present_home_approval(&id);
        let title = card
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("a server");
        let shown = self
            .state
            .sub(&id)
            .is_some_and(|(_, s)| self.approval_shown(s));
        let place = if shown {
            "on its card in Home or its workspace"
        } else {
            "on its card in its workspace (control show)"
        };
        self.queue(
            format!(
                "{id} asks to connect the MCP server {title}. Only the user answers, {place}; \
                 never answer or allow it yourself."
            ),
            Source::Note,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_connect_card_becomes_a_two_answer_request_with_its_facts() {
        let card = json!({
            "requestId": "r-1", "title": "Linear", "publisher": "linear.app", "verified": true,
            "url": "https://mcp.linear.app/mcp", "auth": "oauth", "reason": "file the bug",
            "proposedScope": "chief",
        });
        let request = connect_request(&card).unwrap();
        assert_eq!(
            crate::approval::tool_name(&request),
            "Connect the MCP server Linear"
        );
        assert_eq!(
            request["toolCall"]["rawInput"]["server"],
            "https://mcp.linear.app/mcp"
        );
        assert_eq!(
            request["toolCall"]["_meta"]["acpmux"]["mcpConnect"]["scope"],
            "chief"
        );
        let kinds: Vec<_> = request["options"]
            .as_array()
            .unwrap()
            .iter()
            .map(|o| o["kind"].as_str().unwrap())
            .collect();
        assert_eq!(kinds, ["allow_once", "reject_once"]);
        assert!(connect_request(&json!({"title": "x"})).is_none());
        assert!(is_mcp_connect("mcp-connect:r-1") && !is_mcp_connect("perm-1"));
    }
}
