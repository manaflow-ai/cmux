//! Who sent a request, when a person other than the owner sent it: chat multiplayer (hq#4389).
//! The daemon that admitted the person (`cmux host serve`, by its tailnet WhoIs login) stamps
//! `_meta.acpmux.author {id, name, login?, node?}` on `session/prompt` (a steer too),
//! `_acpmux/permission_respond`, `_acpmux/queue_edit`, `_acpmux/queue_remove`, `_acpmux/view`
//! and `_acpmux/typing`; a client never names itself. `id` is `tailnet:<login>` until accounts
//! are mapped, then `user_…`.
//!
//! Accepted from the unix socket and from a forwarding peer link (a Peer connection held to the
//! peer's rules, never one forwarding for its own Web client), as `fromAgent` is:
//! `server/remote_guard.rs` refuses it from Web, LocalApp and `via: web` with
//! `author.origin_refused`. A peer forwards it as it came (`mark_forwarded` drops only the
//! provenance) and the hub that runs the chat stamps the provenance itself.
//!
//! An author is an audit label plus a restriction: it never stands in for the person's proof
//! (`hub/person.rs`) and never allows anything. It only narrows who changes a queued prompt
//! (`queue.not_author`, `hub/queue_edit.rs`). The hub records it as:
//! - `_meta.provenance {kind: "person_message", from: id, fromName: name, login?, node?}` on the
//!   prompt's `user_message`, `queued` and steer records, kept by the same author's edit;
//! - `answeredBy {id, name}` on `permission_decision`, beside a paired device's `{device,
//!   feedItem}` when the answer names both.
//!
//! A request with no author is the owner's, as before.

use serde_json::{Value, json};

use crate::rpc::RpcError;

/// Where a request carries its author.
pub const POINTER: &str = "/_meta/acpmux/author";
/// The provenance kind of a person's prompt.
pub const PERSON_MESSAGE: &str = "person_message";
/// Longest id, login or node, in bytes.
pub const MAX_FIELD_BYTES: usize = 256;
/// Longest name, in characters.
pub const MAX_NAME_CHARS: usize = 64;

/// A person who sent a request (`_meta.acpmux.author`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Author {
    /// `tailnet:<login>` or `user_…`.
    pub id: String,
    pub name: String,
    /// The tailnet login the daemon admitted.
    pub login: Option<String>,
    /// The machine the person sent it from.
    pub node: Option<String>,
}

impl Author {
    /// The provenance of this person's prompt.
    pub fn provenance(&self) -> Value {
        let mut p = json!({"kind": PERSON_MESSAGE, "from": self.id, "fromName": self.name});
        if let Some(login) = &self.login {
            p["login"] = json!(login);
        }
        if let Some(node) = &self.node {
            p["node"] = json!(node);
        }
        p
    }
}

fn refusal(reason: &str, message: String) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason}))
}

/// Whether `params` carries an author.
pub fn present(params: &Value) -> bool {
    params.pointer(POINTER).is_some_and(|a| !a.is_null())
}

/// The refusal of an author from any origin but the unix socket and a forwarding peer.
pub fn origin_refused() -> RpcError {
    refusal(
        "author.origin_refused",
        "an author is accepted only over the local unix socket or from a forwarding peer".into(),
    )
}

/// The author of a request: `None` when absent or null (the owner's). Fields acpmux does not
/// know are dropped.
pub fn author(params: &Value) -> Result<Option<Author>, RpcError> {
    let raw = match params.pointer(POINTER) {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Object(raw)) => raw,
        Some(_) => return Err(refusal("author.value_refused", "author must be an object".into())),
    };
    let field = |key: &str| -> Result<Option<String>, RpcError> {
        match raw.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(value)) if valid(key, value) => Ok(Some(value.clone())),
            _ => Err(value_refused(key)),
        }
    };
    let required = |key: &str| field(key)?.ok_or_else(|| value_refused(key));
    Ok(Some(Author {
        id: required("id")?,
        name: required("name")?,
        login: field("login")?,
        node: field("node")?,
    }))
}

fn value_refused(key: &str) -> RpcError {
    let need = match key {
        "name" => format!("1 to {MAX_NAME_CHARS} characters"),
        "id" => format!("tailnet:<login> or user_<id>, 1 to {MAX_FIELD_BYTES} bytes"),
        _ => format!("1 to {MAX_FIELD_BYTES} bytes"),
    };
    refusal("author.value_refused", format!("author {key} must be one line of {need}"))
}

fn valid(key: &str, value: &str) -> bool {
    let fits = match key {
        "name" => value.chars().count() <= MAX_NAME_CHARS,
        _ => value.len() <= MAX_FIELD_BYTES,
    };
    let id_shape = key != "id"
        || ["tailnet:", "user_"].iter().any(|prefix| {
            value.strip_prefix(prefix).is_some_and(|rest| !rest.is_empty()) && !value.contains(' ')
        });
    fits && id_shape && !value.trim().is_empty() && !value.chars().any(unshown)
}

/// A character that breaks the one line or changes how it reads: a control, a line or
/// paragraph separator, or a bidi or zero-width format mark (as `prompt_provenance.rs`).
fn unshown(c: char) -> bool {
    c.is_control()
        || (c.is_whitespace() && c != ' ')
        || matches!(
            c,
            '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{FEFF}'
        )
}

/// The person a prompt's provenance names: `None` for the owner, and for an agent's message,
/// which counts as the owner's.
pub fn of_provenance(provenance: Option<&Value>) -> Option<&str> {
    let p = provenance?;
    (p.get("kind").and_then(Value::as_str) == Some(PERSON_MESSAGE))
        .then(|| p.get("from").and_then(Value::as_str))
        .flatten()
}

/// `answeredBy` on a `permission_decision`: a paired device's `{device, feedItem}`
/// (`hub/person.rs` answered_by), with the person's `{id, name}` added when one answered.
pub fn answered_by(device: Option<Value>, author: Option<&Author>) -> Option<Value> {
    let Some(author) = author else { return device };
    let mut by = device.filter(Value::is_object).unwrap_or_else(|| json!({}));
    by["id"] = json!(author.id);
    by["name"] = json!(author.name);
    Some(by)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with(author: Value) -> Value {
        json!({"_meta": {"acpmux": {"author": author}}})
    }

    #[test]
    fn an_author_is_read_checked_and_stamped() {
        assert_eq!(author(&json!({})).unwrap(), None);
        assert_eq!(author(&with(Value::Null)).unwrap(), None);
        let ana = author(&with(json!({"id": "tailnet:ana@example.com", "name": "Ana",
            "login": "ana@example.com", "node": "ana-mbp", "role": "dropped"})))
        .unwrap()
        .unwrap();
        assert_eq!(
            ana.provenance(),
            json!({"kind": "person_message", "from": "tailnet:ana@example.com", "fromName": "Ana",
                   "login": "ana@example.com", "node": "ana-mbp"})
        );
        let bo = author(&with(json!({"id": "user_42", "name": "Bo"}))).unwrap().unwrap();
        assert_eq!(
            bo.provenance(),
            json!({"kind": "person_message", "from": "user_42", "fromName": "Bo"})
        );
        assert_eq!(of_provenance(Some(&bo.provenance())), Some("user_42"));
        assert_eq!(of_provenance(Some(&json!({"kind": "agent_message", "from": "acp:x"}))), None);
        assert_eq!(of_provenance(None), None);
        for bad in [
            json!("tailnet:ana"),
            json!({"name": "Ana"}),
            json!({"id": "tailnet:ana"}),
            json!({"id": "ana", "name": "Ana"}),
            json!({"id": "tailnet:", "name": "Ana"}),
            json!({"id": "tailnet:a b", "name": "Ana"}),
            json!({"id": format!("user_{}", "x".repeat(MAX_FIELD_BYTES)), "name": "Ana"}),
            json!({"id": "user_1", "name": "n".repeat(MAX_NAME_CHARS + 1)}),
            json!({"id": "user_1", "name": "Ana\u{202E}nimda"}),
            json!({"id": "user_1", "name": "Ana", "node": "a\nb"}),
            json!({"id": "user_1", "name": " "}),
            json!({"id": "user_1", "name": "Ana", "login": 7}),
        ] {
            let e = author(&with(bad.clone())).expect_err(&bad.to_string());
            assert_eq!(e.data.unwrap()["reason"], "author.value_refused", "{bad}");
        }
    }

    #[test]
    fn a_persons_answer_adds_id_and_name_beside_a_devices() {
        let ana = Author { id: "user_1".into(), name: "Ana".into(), login: None, node: None };
        let device = json!({"device": "phone-1", "feedItem": "f-1"});
        assert_eq!(answered_by(None, None), None);
        assert_eq!(answered_by(Some(device.clone()), None), Some(device.clone()));
        assert_eq!(answered_by(None, Some(&ana)), Some(json!({"id": "user_1", "name": "Ana"})));
        assert_eq!(
            answered_by(Some(device), Some(&ana)),
            Some(json!({"device": "phone-1", "feedItem": "f-1", "id": "user_1", "name": "Ana"}))
        );
    }
}
