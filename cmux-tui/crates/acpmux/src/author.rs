//! Who sent a request, when a person other than the owner sent it: chat multiplayer (hq#4389).
//! The daemon that admitted the person (`cmux host serve`, by its tailnet WhoIs login) stamps
//! `_meta.acpmux.author {id, name, login?, node?, avatar?}` on `session/prompt` (a steer too),
//! `_acpmux/permission_respond`, `_acpmux/queue_edit`, `_acpmux/queue_remove`, `_acpmux/view`
//! and `_acpmux/typing`; a client never names itself. `id` is `tailnet:<login>` until accounts
//! are mapped, then `user_…`; a link guest on no tailnet and with no account is `guest:<opaque>`.
//! `approval: "owner"` makes the person's prompt wait for the owner (`hub/queue_approve.rs`): it
//! is queued, never steered, and runs only once the owner approves it.
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
//! - `_meta.provenance {kind: "person_message", from: id, fromName: name, fromAvatar?, login?,
//!   node?}` on the prompt's `user_message`, `queued` and steer records, kept by the same
//!   author's edit (`fromAvatar`: the person's profile picture, an `https://` URL);
//! - `answeredBy {id, name}` on `permission_decision`, beside a paired device's `{device,
//!   feedItem}` when the answer names both.
//!
//! A request with no author is the owner's, as before.

use serde_json::{Value, json};

use crate::rpc::RpcError;
use cmux_json::JsonSet as _;

/// Where a request carries its author.
pub const POINTER: &str = "/_meta/acpmux/author";
/// The provenance kind of a person's prompt.
pub const PERSON_MESSAGE: &str = "person_message";
/// Longest id, login or node, in bytes.
pub const MAX_FIELD_BYTES: usize = 256;
/// Longest name, in characters.
pub const MAX_NAME_CHARS: usize = 64;
/// Longest avatar URL, in bytes.
pub const MAX_AVATAR_BYTES: usize = 1024;
/// The one `approval` value: the owner approves each of the person's prompts.
pub const APPROVAL_OWNER: &str = "owner";
/// A link guest's id: on no tailnet and with no account (`cmux-tui-core`
/// `agent_session_shares.rs` binds `guest:<share_id>.<guest_id>`). Every prompt of theirs waits
/// for the owner, `approval` or not: a guest's prompt never runs unapproved.
pub const GUEST_PREFIX: &str = "guest:";

/// Whether `id` is a link guest's (`GUEST_PREFIX`).
pub fn is_guest(id: &str) -> bool {
    id.starts_with(GUEST_PREFIX)
}

/// A person who sent a request (`_meta.acpmux.author`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Author {
    /// `tailnet:<login>`, `user_…` or `guest:<opaque>`.
    pub id: String,
    pub name: String,
    /// The tailnet login the daemon admitted.
    pub login: Option<String>,
    /// The machine the person sent it from.
    pub node: Option<String>,
    /// The person's profile picture: an `https://` URL of printable ASCII, at most
    /// [`MAX_AVATAR_BYTES`] (a signed-in link guest's, `cmux-tui-core` `agent_session_shares.rs`).
    pub avatar: Option<String>,
    /// `approval: "owner"`: each prompt waits for the owner's approval (`hub/queue_approve.rs`).
    pub awaits_owner: bool,
}

impl Author {
    /// The provenance of this person's prompt.
    pub fn provenance(&self) -> Value {
        let mut p = json!({"kind": PERSON_MESSAGE, "from": self.id, "fromName": self.name});
        if let Some(avatar) = &self.avatar {
            p.set("fromAvatar", json!(avatar));
        }
        if let Some(login) = &self.login {
            p.set("login", json!(login));
        }
        if let Some(node) = &self.node {
            p.set("node", json!(node));
        }
        if self.awaits_owner {
            p.set("approval", json!(APPROVAL_OWNER));
        }
        p
    }
}

/// Whether a prompt's provenance says each version of it waits for the owner (`approval`, or a
/// link guest's `from`): an edit by its author waits again (`hub/queue_approve.rs`).
pub fn awaits_owner(provenance: Option<&Value>) -> bool {
    of_provenance(provenance).is_some_and(|from| {
        is_guest(from)
            || provenance.and_then(|p| p.get("approval")).and_then(Value::as_str)
                == Some(APPROVAL_OWNER)
    })
}

/// The `initialize` feature of a daemon that holds a prompt for the owner: a peer forwards one,
/// and the owner's answer to one, only to a peer that lists it (`server/peer_forward.rs`).
pub const QUEUE_APPROVAL_FEATURE: &str = "queueApproval";
/// The `initialize` feature of a daemon that serves `_acpmux/queue_get`: forwarded to a peer only
/// when it lists it, on the link that listed it (`server/peer_forward.rs`).
pub const QUEUE_GET_FEATURE: &str = "queueGet";

/// `queue.approval_unsupported`: a prompt that waits for the owner, or an answer to one, for a
/// peer on an older build, which would run the prompt unapproved. Nothing is forwarded.
pub fn approval_unsupported(peer: &crate::peer::Peer) -> RpcError {
    let build = peer.remote_build().unwrap_or_else(|| "unknown".into());
    let (name, msg) = (&peer.name, "which does not hold a prompt for the owner");
    let message = format!(
        "queue.approval_unsupported: peer {name} runs acpmux build {build}, {msg}; run `acpmux machine update {name}`"
    );
    refusal("queue.approval_unsupported", message)
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

/// The author of a `session/prompt`, checked before it runs here or goes to a peer
/// (`server/peer_forward.rs`, where `mark_forwarded` drops the provenance): a prompt is a
/// person's or another sender's (`_meta.acpmux.provenance`), never both.
pub fn of_prompt(params: &Value) -> Result<Option<Author>, RpcError> {
    let author = author(params)?;
    if author.is_some() && crate::prompt_provenance::present(params.pointer("/_meta/acpmux")) {
        return Err(refusal(
            "author.value_refused",
            "a prompt names its author or a provenance, never both".into(),
        ));
    }
    Ok(author)
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
    let awaits_owner = match raw.get("approval") {
        None | Some(Value::Null) => false,
        Some(Value::String(value)) if value == APPROVAL_OWNER => true,
        _ => return Err(value_refused("approval")),
    };
    let id = required("id")?;
    // A link guest's prompt waits for the owner even when its sender left `approval` off.
    let awaits_owner = awaits_owner || is_guest(&id);
    Ok(Some(Author {
        id,
        name: required("name")?,
        login: field("login")?,
        node: field("node")?,
        avatar: field("avatar")?,
        awaits_owner,
    }))
}

/// `queue.owner_only`: only the owner (a request with no author) approves or declines a prompt
/// that waits for them (`_acpmux/queue_approve`, `_acpmux/queue_decline`).
pub fn owner_only(params: &Value) -> Result<(), RpcError> {
    if present(params) {
        return Err(refusal(
            "queue.owner_only",
            "queue.owner_only: only the chat's owner approves or declines a waiting prompt".into(),
        ));
    }
    Ok(())
}

fn value_refused(key: &str) -> RpcError {
    let need = match key {
        "name" => format!("1 to {MAX_NAME_CHARS} characters"),
        "id" => format!("tailnet:<login>, user_<id> or guest:<id>, 1 to {MAX_FIELD_BYTES} bytes"),
        "approval" => format!("\"{APPROVAL_OWNER}\""),
        "avatar" => format!("an https:// URL, 9 to {MAX_AVATAR_BYTES} bytes"),
        _ => format!("1 to {MAX_FIELD_BYTES} bytes"),
    };
    refusal("author.value_refused", format!("author {key} must be one line of {need}"))
}

fn valid(key: &str, value: &str) -> bool {
    if key == "avatar" {
        return value.len() <= MAX_AVATAR_BYTES
            && value.len() > "https://".len()
            && value.starts_with("https://")
            && value.bytes().all(|b| b.is_ascii_graphic());
    }
    let fits = match key {
        "name" => value.chars().count() <= MAX_NAME_CHARS,
        _ => value.len() <= MAX_FIELD_BYTES,
    };
    let id_shape = key != "id"
        || ["tailnet:", "user_", GUEST_PREFIX].iter().any(|prefix| {
            value.strip_prefix(prefix).is_some_and(|rest| !rest.is_empty()) && !value.contains(' ')
        });
    fits && id_shape && !value.trim().is_empty() && !value.chars().any(unshown)
}

/// A character that breaks the one line or changes how it reads: a control, a line or
/// paragraph separator, or a bidi or zero-width format mark (as `prompt_provenance.rs`).
pub(crate) fn unshown(c: char) -> bool {
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

/// The person a prompt's provenance names, as a queue list shows them (`QueuedPromptSummary`
/// `author`, `_acpmux/composers`): `{id, name}`, the name falling back to the id when a record
/// names none; `None` for the owner and for an agent's message.
pub fn listed(provenance: Option<&Value>) -> Option<crate::protocol::session::QueuedAuthor> {
    let id = of_provenance(provenance)?;
    let name = provenance
        .and_then(|p| p.get("fromName"))
        .and_then(Value::as_str)
        .filter(|name| !name.trim().is_empty())
        .unwrap_or(id);
    let avatar = provenance
        .and_then(|p| p.get("fromAvatar"))
        .and_then(Value::as_str)
        .filter(|avatar| valid("avatar", avatar))
        .map(str::to_owned);
    Some(crate::protocol::session::QueuedAuthor {
        id: id.to_owned(),
        name: name.to_owned(),
        avatar,
    })
}

/// What the agent reads before a person's prompt (not the owner's, nor an agent's message): who
/// sent it, so the agent knows which participant of a shared chat is asking. The agent's copy
/// only: the transcript's `user_message` keeps the person's own words.
pub fn agent_label(provenance: Option<&Value>) -> Option<Value> {
    let id = of_provenance(provenance)?;
    let name = listed(provenance).map_or_else(|| id.to_owned(), |a| a.name);
    let who = if is_guest(id) { "a guest" } else { "a participant" };
    Some(json!({"type": "text",
        "text": format!("[Message from {name}, {who} in this shared chat]")}))
}

/// Who changes a queued prompt or an unread steer (`hub/queue_edit.rs`, `_acpmux/queue_remove`):
/// `Some(author id)`, `Some(None)` for the owner, checked against the prompt's sender under the
/// lock that changes it; `None` is the hub's own change, never checked.
pub type Editor<'a> = Option<Option<&'a str>>;

/// The editor of a request (`author(params)`), checked from here on.
pub fn editor(author: Option<&Author>) -> Editor<'_> {
    Some(author.map(|a| a.id.as_str()))
}

/// `queue.not_author` unless `editor` may change a prompt sent by `sender` (`of_provenance`):
/// only the same person, the owner counting as one (an agent's message is the owner's).
pub fn may_change(editor: Editor<'_>, sender: Option<&str>) -> Result<(), crate::rpc::RpcError> {
    match editor {
        Some(id) if id != sender => Err(refusal(
            "queue.not_author",
            "queue.not_author: only the person who sent this prompt may change it".into(),
        )),
        _ => Ok(()),
    }
}

/// The supersede key a restored `queued` record runs under (`hub/queue.rs` restore): none for a
/// person's prompt, which a key never replaces (`supersede.rs` knows agents and the owner only),
/// whatever an older daemon wrote.
pub fn restored_supersede(queued: &Value) -> Option<&str> {
    let person = of_provenance(queued.pointer("/_meta/provenance")).is_some();
    queued.get("supersede").and_then(Value::as_str).filter(|_| !person)
}

/// `answeredBy` on a `permission_decision`: a paired device's `{device, feedItem}`
/// (`hub/person.rs` answered_by), with the person's `{id, name}` added when one answered.
pub fn answered_by(device: Option<Value>, author: Option<&Author>) -> Option<Value> {
    let Some(author) = author else { return device };
    let mut by = device.filter(Value::is_object).unwrap_or_else(|| json!({}));
    by.set("id", json!(author.id));
    by.set("name", json!(author.name));
    Some(by)
}

#[cfg(test)]
mod tests;
