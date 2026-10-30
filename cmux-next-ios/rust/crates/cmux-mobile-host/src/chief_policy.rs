//! The `chief` service's line filter: a phone of the Mac's owner talking to
//! the Chief's conversation owner (the cmux-tui session `cmux-chief-<hash>`
//! of `~/.cmux/chief/<account>`, plans/cmux-next/home-state-ownership.md).
//!
//! cmux-mobile-host reaches that daemon over its Unix socket, so the daemon treats
//! every line as the Mac owner's own trusted connection (`user_local`). This
//! filter is the only place a phone's authority over Chief is narrowed. It
//! follows the rules of the daemon's own remote relay gate
//! (`cmux-tui-core/src/server/remote_relay/gate.rs`): default deny, a
//! command passes only by its exact name with exactly the params listed,
//! command-bearing params are refused everywhere, ids must be plain
//! owner-made ids, and op kinds and message parts are allowlisted. Beyond
//! the relay it allows what Chief on the Mac does for its owner (attachments,
//! threads, search, rename, question answers and the brain's engine
//! controls), and it scopes every object: a phone sees and writes only
//! conversations between the owner (`user_local`) and agents (`agent_*`).
//! Events and list replies for any other conversation never reach the
//! phone. See cmux-next-ios/verify/relay-security.md, "Chief".

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, PoisonError};

use serde_json::{Map, Value};

use crate::policy::{MAXIMUM_LINE_BYTES, Verdict, error_line};

/// Params that carry a command to run. Refused on every command and op
/// (the relay gate's list).
const COMMAND_PARAMS: &[&str] = &["initial_command", "command", "tmux_start_command", "pane_start_command"];

/// The owner, as the daemon names the human on a trusted local connection.
const OWNER: &str = "user_local";

/// v12 commands a phone may send, with exactly the params each accepts.
/// Not listed (refused): `conversation-create` (the Mac creates Chief),
/// `conversation-import`, `conversation-bind`, `conversation-agent-token`
/// (would let the phone speak as Chief), `conversation-draft` (agents only),
/// `chief-inspect` (the memory inspector stays on the Mac), every `cloud-*`
/// and every non-conversation command.
pub const ALLOWED_COMMANDS: &[(&str, &[&str])] = &[
    ("identify", &[]),
    ("ping", &[]),
    ("subscribe", &[]),
    ("conversation-list", &[]),
    ("conversation-snapshot", &["conversation", "tail"]),
    ("conversation-history", &["conversation", "before_seq", "limit"]),
    ("conversation-thread", &["conversation", "root", "after_seq", "limit"]),
    ("conversation-search", &["query", "limit"]),
    ("conversation-op", &["conversation", "idempotency_key", "transaction", "op", "approval"]),
    ("conversation-typing", &["conversation", "on"]),
    (
        "conversation-attachment-upload",
        &[
            "op",
            "conversation",
            "sha256",
            "byte_count",
            "mime_type",
            "name",
            "width",
            "height",
            "duration_ms",
            "poster",
            "preview",
            "upload",
            "piece",
            "offset",
            "data",
        ],
    ),
    ("conversation-attachment-read", &["conversation", "hash", "variant", "offset", "length"]),
    // Home: the Mac's Home list (the local owner's rows only, narrowed to the
    // scope) and the person's own pin and unread mark of a conversation in it.
    ("home-inbox", &["owners"]),
    ("conversation-inbox-op", &["conversation", "op"]),
];

/// `conversation-inbox-op` kinds a phone may send, with their exact fields
/// (`inbox.mute` is the Cloud owner's and is not here).
const ALLOWED_INBOX_OPS: &[(&str, &[&str])] =
    &[("inbox.pin", &["pinned", "position"]), ("inbox.mark_unread", &["unread"])];

/// Op kinds a phone may send, with their exact fields. Refused by omission:
/// `participants.add` (it would widen the conversation, and the scope), and
/// agent-only fields (`answers`, `answers_pending`).
const ALLOWED_OPS: &[(&str, &[&str])] = &[
    ("message.send", &["client_msg_id", "parts", "reply_to", "thread_root"]),
    ("message.edit", &["message_id", "parts"]),
    ("message.retract", &["message_id"]),
    ("reaction.add", &["message_id", "part_index", "reaction"]),
    ("reaction.remove", &["message_id", "part_index", "reaction"]),
    ("read_cursor.set", &["seq"]),
    ("title.set", &["title"]),
    ("question.answer", &["message_id", "part_index", "answer"]),
];

const TEXT_PART_FIELDS: &[&str] = &["type", "text", "runs"];
const TEXT_RUN_FIELDS: &[&str] = &["start", "length", "mention", "link"];
const ATTACHMENT_PART_FIELDS: &[&str] = &[
    "type",
    "hash",
    "name",
    "mime_type",
    "byte_count",
    "width",
    "height",
    "duration_ms",
    "poster",
    "preview",
];
const REPLY_TO_FIELDS: &[&str] = &["message_id", "part_index"];

/// `cmux.protocol/2` operations a phone may send: the brain's engine
/// controls the Mac's Chief settings use (ChiefControlClient). The daemon
/// answers them only on the owner's trusted connection, which this is.
const ALLOWED_RESOURCE_OPERATIONS: &[(&str, &[&str])] = &[
    ("chief.engine.get", &["machine", "session"]),
    ("chief.engine.set", &["machine", "session", "harness", "model", "effort", "speed", "compactor_speed"]),
    ("chief.stop", &["machine", "session", "name"]),
];
const RESOURCE_FIELDS: &[&str] = &["protocol", "type", "id", "operation", "params", "idempotency_key"];

/// Events a phone receives, for conversations in scope only.
const FORWARDED_EVENTS: &[&str] = &["conversation-changed", "conversation-typing", "conversation-inbox-changed"];

/// Requests a phone may have waiting for a reply at once.
pub const MAXIMUM_IN_FLIGHT: usize = 256;

/// What a forwarded request's reply needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pending {
    /// `conversation-list`: keep only conversations in scope, and learn them.
    List,
    /// `conversation-search`: keep only hits in scope.
    Search,
    /// `home-inbox`: keep only the local owner's rows in scope.
    Inbox,
}

#[derive(Debug, Default)]
struct Scope {
    /// Conversations the phone may name: listed (or announced) by the owner
    /// and between the owner and agents only.
    allowed: HashSet<String>,
    /// Every forwarded request waiting for its reply, by `id` (as JSON
    /// text), with what its reply needs. An id is never reused while it
    /// waits, so a reply cannot be taken for another request's.
    in_flight: HashMap<String, Option<Pending>>,
}

/// The per-channel policy; clones share one scope (one per direction).
#[derive(Debug, Clone, Default)]
pub struct ChiefPolicy {
    scope: Arc<Mutex<Scope>>,
    /// Supervised: a `question.answer` counts only with this phone's signed
    /// approval (`chief_answers.rs`). None (unsupervised): no keys to check.
    answers: Option<crate::chief_answers::AnswerCheck>,
}

/// True for a conversation between the owner and agents only.
pub fn in_scope(summary: &Value) -> bool {
    let Some(participants) = summary.get("participants").and_then(Value::as_array) else { return false };
    let mut has_owner = false;
    for participant in participants {
        let id = participant.get("id").and_then(Value::as_str).unwrap_or_default();
        let kind = participant.get("kind").and_then(Value::as_str).unwrap_or_default();
        if id == OWNER && kind == "human" {
            has_owner = true;
        } else if !(kind == "agent" && plain_id(id, "agent_")) {
            return false;
        }
    }
    has_owner
}

impl ChiefPolicy {
    pub fn new() -> Self {
        Self::default()
    }

    /// A paired link's policy: its `question.answer`s need the phone's signature.
    pub fn signed(answers: crate::chief_answers::AnswerCheck) -> Self {
        Self { answers: Some(answers), ..Self::default() }
    }

    fn with_scope<T>(&self, f: impl FnOnce(&mut Scope) -> T) -> T {
        f(&mut self.scope.lock().unwrap_or_else(PoisonError::into_inner))
    }

    /// Judge one newline-stripped phone request line.
    pub fn evaluate(&self, line: &[u8]) -> Verdict {
        if line.len() > MAXIMUM_LINE_BYTES {
            return Verdict::Refuse(error_line(None, "too_large", "request exceeds 4 MiB"));
        }
        let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(line) else {
            return Verdict::Refuse(error_line(None, "bad_request", "request is not a JSON object"));
        };
        let id = object.get("id");
        // Every request names itself, so its reply is matched to it alone.
        let Some(key) = id.filter(|id| id.is_string() || id.is_u64()).map(Value::to_string) else {
            return Verdict::Refuse(error_line(id, "bad_request", "a request needs a string or integer id"));
        };
        let busy = self.with_scope(|scope| {
            if scope.in_flight.contains_key(&key) {
                Some("this id is still waiting for its reply")
            } else if scope.in_flight.len() >= MAXIMUM_IN_FLIGHT {
                Some("too many requests waiting")
            } else {
                None
            }
        });
        if let Some(why) = busy {
            return Verdict::Refuse(error_line(id, "bad_request", why));
        }
        if object.contains_key("protocol") {
            return match check_resource(&object) {
                Ok(()) => {
                    self.with_scope(|scope| scope.in_flight.insert(key, None));
                    Verdict::Forward
                }
                Err(why) => Verdict::Refuse(resource_refusal(id, &why)),
            };
        }
        let refuse = |why: String| Verdict::Refuse(error_line(id, "forbidden", &why));
        let Some(command) = object.get("cmd").and_then(Value::as_str) else {
            return Verdict::Refuse(error_line(id, "bad_request", "missing cmd"));
        };
        let Some((_, params)) = ALLOWED_COMMANDS.iter().find(|(name, _)| *name == command) else {
            return refuse(format!("{command} is not available to a phone"));
        };
        if let Err(why) = check_fields(&object, params, &["id", "cmd"]) {
            return refuse(format!("{command}: {why}"));
        }
        if let Some(conversation) = object.get("conversation") {
            let Some(conversation) = conversation.as_str().filter(|c| plain_id(c, "conv_")) else {
                return refuse(format!("{command}: conversation is not a plain id"));
            };
            if !self.with_scope(|scope| scope.allowed.contains(conversation)) {
                return refuse(format!(
                    "{command}: {conversation} is not a Chief conversation of this phone"
                ));
            }
        }
        if let Some(root) = object.get("root")
            && !root.as_str().is_some_and(|r| plain_id(r, "msg_"))
        {
            return refuse(format!("{command}: root is not a plain id"));
        }
        let mut rewrite = None;
        match object.get("op").filter(|_| command == "conversation-op") {
            Some(op) => {
                if let Err(why) = check_op(op) {
                    return refuse(format!("{command}: {why}"));
                }
                let answers = op.get("kind").and_then(Value::as_str) == Some("question.answer");
                if !answers && object.contains_key("approval") {
                    return refuse(format!("{command}: approval is only for question.answer"));
                }
                if answers {
                    // A question's answer may grant something: it counts with the
                    // iPhone's Face ID signature only (chief_answers.rs).
                    if let Some(check) = &self.answers {
                        let conversation =
                            object.get("conversation").and_then(Value::as_str).unwrap_or_default();
                        if let Err(why) = check.verify(conversation, op, object.get("approval")) {
                            return refuse(format!("{command}: {why}"));
                        }
                    }
                    if object.contains_key("approval") {
                        let mut stripped = object.clone();
                        stripped.remove("approval");
                        rewrite = serde_json::to_vec(&Value::Object(stripped)).ok();
                    }
                }
            }
            None if command == "conversation-op" => return refuse("conversation-op: missing op".into()),
            None => {}
        }
        if command == "conversation-attachment-upload"
            && let Err(why) = check_upload(&object)
        {
            return refuse(format!("{command}: {why}"));
        }
        if command == "home-inbox" && let Err(why) = check_home_inbox(&object) {
            return refuse(format!("{command}: {why}"));
        }
        if command == "conversation-inbox-op" {
            if !object.contains_key("conversation") {
                return refuse(format!("{command}: missing conversation"));
            }
            if let Err(why) = check_inbox_op(object.get("op")) {
                return refuse(format!("{command}: {why}"));
            }
        }
        let pending = match command {
            "conversation-list" => Some(Pending::List),
            "conversation-search" => Some(Pending::Search),
            "home-inbox" => Some(Pending::Inbox),
            _ => None,
        };
        self.with_scope(|scope| scope.in_flight.insert(key, pending));
        match rewrite {
            Some(line) => Verdict::Rewrite(line),
            None => Verdict::Forward,
        }
    }

    /// Filter one newline-stripped line from the daemon: `None` drops it,
    /// `Some` is what the phone gets (the line itself, or a narrowed copy).
    pub fn filter_reply(&self, line: &[u8]) -> Option<Vec<u8>> {
        let Ok(Value::Object(mut object)) = serde_json::from_slice::<Value>(line) else {
            // Nothing the owner sends is not a JSON object; drop it.
            return None;
        };
        if let Some(event) = object.get("event").and_then(Value::as_str) {
            return self.filter_event(event, &object).then(|| line.to_vec());
        }
        let Some(id) = object.get("id").map(Value::to_string) else {
            // A v2 response carries an id; anything else is not for the phone.
            return None;
        };
        // Only replies to requests this phone sent, each once.
        let pending = self.with_scope(|scope| scope.in_flight.remove(&id))?;
        let Some(pending) = pending else {
            return Some(line.to_vec());
        };
        let Some(Value::Object(data)) = object.get_mut("data") else { return Some(line.to_vec()) };
        match pending {
            Pending::List => {
                let kept: Vec<Value> = data
                    .get("conversations")
                    .and_then(Value::as_array)
                    .map(|all| all.iter().filter(|summary| in_scope(summary)).cloned().collect())
                    .unwrap_or_default();
                // The owner's whole list: the scope is exactly what it holds now.
                self.with_scope(|scope| {
                    scope.allowed = kept
                        .iter()
                        .filter_map(|summary| summary.get("id").and_then(Value::as_str))
                        .filter(|conversation| plain_id(conversation, "conv_"))
                        .map(str::to_owned)
                        .collect();
                });
                data.insert("conversations".into(), Value::Array(kept));
            }
            Pending::Search => {
                let allowed = self.with_scope(|scope| scope.allowed.clone());
                let kept: Vec<Value> = data
                    .get("hits")
                    .and_then(Value::as_array)
                    .map(|all| {
                        all.iter()
                            .filter(|hit| {
                                hit.get("conversation")
                                    .and_then(Value::as_str)
                                    .is_some_and(|c| allowed.contains(c))
                            })
                            .cloned()
                            .collect()
                    })
                    .unwrap_or_default();
                data.insert("hits".into(), Value::Array(kept));
            }
            Pending::Inbox => {
                let allowed = self.with_scope(|scope| scope.allowed.clone());
                let kept: Vec<Value> = data
                    .get("rows")
                    .and_then(Value::as_array)
                    .map(|all| {
                        all.iter()
                            .filter(|row| {
                                row.get("owner").and_then(Value::as_str).unwrap_or("local") == "local"
                                    && row.get("id").and_then(Value::as_str).is_some_and(|c| allowed.contains(c))
                            })
                            .cloned()
                            .collect()
                    })
                    .unwrap_or_default();
                data.insert("rows".into(), Value::Array(kept));
            }
        }
        serde_json::to_vec(&Value::Object(object)).ok()
    }

    /// Conversation events in scope pass; a conversation the owner announces
    /// (`change.kind:"conversation"`) joins or leaves the scope by its
    /// participants. Every other event (terminal, workspace, cloud) is dropped.
    fn filter_event(&self, event: &str, object: &Map<String, Value>) -> bool {
        // Missed events: the phone refetches. It carries no conversation data.
        if event == "overflow" {
            return true;
        }
        if !FORWARDED_EVENTS.contains(&event) {
            return false;
        }
        let Some(conversation) = object.get("conversation").and_then(Value::as_str) else { return false };
        // The person's own list state, never an agent's.
        if event == "conversation-inbox-changed" && object.get("participant").and_then(Value::as_str) != Some(OWNER) {
            return false;
        }
        let change = object.get("change");
        if change.and_then(|c| c.get("kind")).and_then(Value::as_str) == Some("conversation")
            && let Some(summary) = change.and_then(|c| c.get("conversation"))
        {
            let keep = in_scope(summary) && plain_id(conversation, "conv_");
            self.with_scope(|scope| {
                if keep {
                    scope.allowed.insert(conversation.to_owned());
                } else {
                    scope.allowed.remove(conversation);
                }
            });
            return keep;
        }
        self.with_scope(|scope| scope.allowed.contains(conversation))
    }
}

/// A plain owner-made id: `prefix` then 1-64 ASCII letters and digits (the
/// relay gate's rule; `agent_` ids also allow `_` and `-`).
fn plain_id(value: &str, prefix: &str) -> bool {
    value.strip_prefix(prefix).is_some_and(|rest| {
        !rest.is_empty()
            && rest.len() <= 64
            && rest
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || (prefix == "agent_" && matches!(b, b'_' | b'-')))
    })
}

fn check_fields(object: &Map<String, Value>, allowed: &[&str], always: &[&str]) -> Result<(), String> {
    for key in object.keys() {
        if COMMAND_PARAMS.contains(&key.as_str()) {
            return Err(format!("{key} is refused"));
        }
        if !allowed.contains(&key.as_str()) && !always.contains(&key.as_str()) {
            return Err(format!("{key} is not accepted from a phone"));
        }
    }
    Ok(())
}

fn check_op(value: &Value) -> Result<(), String> {
    let Value::Object(op) = value else { return Err("op is not an object".into()) };
    let Some(kind) = op.get("kind").and_then(Value::as_str) else { return Err("op has no kind".into()) };
    let Some((_, fields)) = ALLOWED_OPS.iter().find(|(name, _)| *name == kind) else {
        return Err(format!("op {kind} is not available to a phone"));
    };
    check_fields(op, fields, &["kind"])?;
    for key in ["message_id", "thread_root"] {
        if let Some(message) = op.get(key)
            && !message.as_str().is_some_and(|m| plain_id(m, "msg_"))
        {
            return Err(format!("{key} is not a plain id"));
        }
    }
    if let Some(reply_to) = op.get("reply_to") {
        let Value::Object(reply_to) = reply_to else { return Err("reply_to is not an object".into()) };
        check_fields(reply_to, REPLY_TO_FIELDS, &[])?;
        if !reply_to.get("message_id").and_then(Value::as_str).is_some_and(|m| plain_id(m, "msg_")) {
            return Err("reply_to.message_id is not a plain id".into());
        }
    }
    match op.get("parts") {
        Some(Value::Array(parts)) => parts.iter().try_for_each(check_part),
        Some(_) => Err("parts is not an array".into()),
        None => Ok(()),
    }
}

/// Text parts (with runs) and attachment parts by hash. `work`, `question`
/// and `link_preview` parts are agents' or refused by name.
fn check_part(part: &Value) -> Result<(), String> {
    let Value::Object(part) = part else { return Err("a part is not an object".into()) };
    match part.get("type").and_then(Value::as_str) {
        Some("text") => {
            check_fields(part, TEXT_PART_FIELDS, &[])?;
            match part.get("runs") {
                None | Some(Value::Null) => Ok(()),
                Some(Value::Array(runs)) => runs.iter().try_for_each(|run| match run {
                    Value::Object(run) => check_fields(run, TEXT_RUN_FIELDS, &[]),
                    _ => Err("a run is not an object".into()),
                }),
                Some(_) => Err("runs is not an array".into()),
            }
        }
        Some("attachment") => check_fields(part, ATTACHMENT_PART_FIELDS, &[]),
        Some(other) => Err(format!("{other} parts are not available to a phone")),
        None => Err("a part has no type".into()),
    }
}

/// `home-inbox` asks for the local owner's rows only: the person's Cloud
/// inbox never crosses the link.
fn check_home_inbox(object: &Map<String, Value>) -> Result<(), String> {
    match object.get("owners").and_then(Value::as_array).map(Vec::as_slice) {
        Some([only]) if only.as_str() == Some("local") => Ok(()),
        _ => Err("owners must be [\"local\"]".into()),
    }
}

/// A pin (with an optional position) or an unread mark, values typed.
fn check_inbox_op(value: Option<&Value>) -> Result<(), String> {
    let Some(Value::Object(op)) = value else { return Err("op is not an object".into()) };
    let Some(kind) = op.get("kind").and_then(Value::as_str) else { return Err("op has no kind".into()) };
    let Some((_, fields)) = ALLOWED_INBOX_OPS.iter().find(|(name, _)| *name == kind) else {
        return Err(format!("op {kind} is not available to a phone"));
    };
    check_fields(op, fields, &["kind"])?;
    for key in ["pinned", "unread"] {
        if op.get(key).is_some_and(|v| !v.is_boolean()) {
            return Err(format!("{key} is not a bool"));
        }
    }
    if op.get("position").is_some_and(|v| !v.is_u64()) {
        return Err("position is not an unsigned integer".into());
    }
    if kind == "inbox.pin" && !op.contains_key("pinned") || kind == "inbox.mark_unread" && !op.contains_key("unread") {
        return Err(format!("op {kind} is missing its value"));
    }
    Ok(())
}

/// An upload names a conversation (checked above) on `begin`; the other
/// steps name the upload the same connection began.
fn check_upload(object: &Map<String, Value>) -> Result<(), String> {
    match object.get("op").and_then(Value::as_str) {
        Some("begin") if object.contains_key("conversation") => Ok(()),
        Some("begin") => Err("begin names no conversation".into()),
        Some("chunk" | "commit" | "cancel") if !object.contains_key("conversation") => Ok(()),
        Some(step) => Err(format!("upload step {step} is not available to a phone")),
        None => Err("missing op".into()),
    }
}

fn check_resource(object: &Map<String, Value>) -> Result<(), String> {
    check_fields(object, RESOURCE_FIELDS, &[])?;
    if object.get("protocol").and_then(Value::as_str) != Some("cmux.protocol/2")
        || object.get("type").and_then(Value::as_str) != Some("request")
    {
        return Err("only cmux.protocol/2 requests".into());
    }
    let operation = object.get("operation").and_then(Value::as_str).unwrap_or_default();
    let Some((_, params)) = ALLOWED_RESOURCE_OPERATIONS.iter().find(|(name, _)| *name == operation) else {
        return Err(format!("{operation} is not available to a phone"));
    };
    let Some(Value::Object(fields)) = object.get("params") else {
        return Err("params is not an object".into());
    };
    check_fields(fields, params, &[])?;
    for key in ["machine", "session"] {
        if fields.get(key).is_some_and(|v| v.as_str() != Some("current")) {
            return Err(format!("{key} must be current"));
        }
    }
    if fields.iter().any(|(key, value)| key != "machine" && key != "session" && !value.is_string()) {
        return Err("engine fields are strings".into());
    }
    Ok(())
}

/// A v2 failure response, so the phone's resource client reads it as one.
fn resource_refusal(id: Option<&Value>, why: &str) -> String {
    serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "response",
        "id": id.cloned().unwrap_or(Value::Null),
        "ok": false,
        "error": {"code": "origin.forbidden", "message": why, "details": {"reason": "phone_policy"}, "retryable": false},
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const CHIEF: &str = "conv_01JCHIEF000000000000000000";
    const OTHER: &str = "conv_01JOTHER000000000000000000";
    const REMOTE: &str = "conv_01JREMOTE00000000000000000";

    fn listed() -> ChiefPolicy {
        let policy = ChiefPolicy::new();
        assert_eq!(policy.evaluate(br#"{"cmd":"conversation-list","id":"m1"}"#), Verdict::Forward);
        let reply = serde_json::json!({"id": "m1", "ok": true, "data": {"conversations": [
            {"id": CHIEF, "participants": [
                {"id": "user_local", "kind": "human", "display_name": "A"},
                {"id": "agent_mux", "kind": "agent", "display_name": "Chief", "agent_class": "mux"}]},
            {"id": OTHER, "participants": [
                {"id": "user_local", "kind": "human", "display_name": "A"},
                {"id": "agent_mux", "kind": "agent", "display_name": "Chief"},
                {"id": "agent_codex-1", "kind": "agent", "display_name": "Codex"}]},
            {"id": REMOTE, "participants": [
                {"id": "user_local", "kind": "human", "display_name": "A"},
                {"id": "remote_ab12", "kind": "human", "display_name": "Phone"}]},
        ]}});
        let narrowed = policy.filter_reply(reply.to_string().as_bytes()).unwrap();
        let narrowed: Value = serde_json::from_slice(&narrowed).unwrap();
        let ids: Vec<&str> = narrowed["data"]["conversations"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, [CHIEF, OTHER]);
        policy
    }

    fn line(value: Value) -> Vec<u8> {
        value.to_string().into_bytes()
    }

    fn refused(policy: &ChiefPolicy, value: Value) {
        assert!(matches!(policy.evaluate(&line(value.clone())), Verdict::Refuse(_)), "forwarded {value}");
    }

    /// Supervised, a question answer needs the phone's signed approval
    /// (chief_answers.rs has the signature cases); approval rides only on one.
    #[test]
    fn a_paired_links_question_answer_needs_its_approval() {
        let trust = crate::pairing::DeviceTrust::default();
        let signed = ChiefPolicy::signed(crate::chief_answers::AnswerCheck {
            mac: "mac".into(),
            phone: "phone".into(),
            trust: tokio::sync::watch::channel(Some(trust)).1,
            spent: Arc::default(),
        });
        let listed_signed = {
            let unsigned = listed();
            signed.with_scope(|scope| scope.allowed = unsigned.with_scope(|s| s.allowed.clone()));
            signed
        };
        let answer = serde_json::json!({"cmd": "conversation-op", "id": "q1", "conversation": CHIEF,
            "idempotency_key": "k", "op": {"kind": "question.answer", "message_id": "msg_01Q", "part_index": 0,
            "answer": {"selections": {}}}});
        refused(&listed_signed, answer.clone());
        let mut forged = answer.clone();
        forged["id"] = serde_json::json!("q2");
        forged["approval"] = serde_json::json!({"approver": "phone", "nonce": "0123456789abcdef",
            "expiresAt": 1, "signature": "00"});
        refused(&listed_signed, forged);
        let send = serde_json::json!({"cmd": "conversation-op", "id": "q3", "conversation": CHIEF,
            "idempotency_key": "k", "approval": {}, "op": {"kind": "message.send", "client_msg_id": "c",
            "parts": [{"type": "text", "text": "hi"}]}});
        refused(&listed_signed, send);
        // Unsupervised (no keys), an answer passes as before, its approval stripped.
        let plain = listed();
        let mut with_approval = answer;
        with_approval["approval"] = serde_json::json!({});
        match plain.evaluate(&line(with_approval)) {
            Verdict::Rewrite(bytes) => {
                let sent: Value = serde_json::from_slice(&bytes).unwrap();
                assert!(sent.get("approval").is_none());
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_ios_chief_session_passes() {
        let policy = listed();
        for value in [
            serde_json::json!({"cmd": "identify", "id": "m0"}),
            serde_json::json!({"cmd": "subscribe", "id": "m2"}),
            serde_json::json!({"cmd": "conversation-snapshot", "id": "m3", "conversation": CHIEF, "tail": 50}),
            serde_json::json!({"cmd": "conversation-history", "id": "m4", "conversation": CHIEF, "before_seq": 9, "limit": 50}),
            serde_json::json!({"cmd": "conversation-thread", "id": "m5", "conversation": CHIEF, "root": "msg_01ABC", "limit": 50}),
            serde_json::json!({"cmd": "conversation-typing", "id": "m6", "conversation": CHIEF, "on": true}),
            serde_json::json!({"cmd": "conversation-search", "id": "m7", "query": "build", "limit": 20}),
            serde_json::json!({"cmd": "conversation-op", "id": "m8", "conversation": CHIEF, "idempotency_key": "c_1",
                "op": {"kind": "message.send", "client_msg_id": "c_1", "parts": [
                    {"type": "attachment", "hash": "ab", "name": "IMG.jpg", "mime_type": "image/jpeg", "byte_count": 3, "width": 1, "height": 1},
                    {"type": "text", "text": "hi @Chief", "runs": [{"start": 3, "length": 6, "mention": "agent_mux"}]}],
                    "reply_to": {"message_id": "msg_01A", "part_index": 0}}}),
            serde_json::json!({"cmd": "conversation-op", "id": "m9", "conversation": CHIEF, "idempotency_key": "k",
                "op": {"kind": "read_cursor.set", "seq": 4}}),
            serde_json::json!({"cmd": "conversation-op", "id": "m10", "conversation": CHIEF, "idempotency_key": "k2",
                "op": {"kind": "reaction.add", "message_id": "msg_01A", "part_index": 0, "reaction": {"tapback": "love"}}}),
            serde_json::json!({"cmd": "conversation-op", "id": "m11", "conversation": CHIEF, "idempotency_key": "k3",
                "op": {"kind": "title.set", "title": "Chief"}}),
            serde_json::json!({"cmd": "conversation-op", "id": "m12", "conversation": CHIEF, "idempotency_key": "k4",
                "op": {"kind": "question.answer", "message_id": "msg_01Q", "part_index": 0, "answer": {"selections": {}}}}),
            serde_json::json!({"cmd": "conversation-attachment-upload", "id": "m13", "op": "begin", "conversation": CHIEF,
                "sha256": "ab", "byte_count": 3, "mime_type": "image/jpeg", "name": "IMG.jpg", "width": 1, "height": 1}),
            serde_json::json!({"cmd": "conversation-attachment-upload", "id": "m14", "op": "chunk", "upload": "u1",
                "piece": "original", "offset": 0, "data": "AAAA"}),
            serde_json::json!({"cmd": "conversation-attachment-upload", "id": "m15", "op": "commit", "upload": "u1"}),
            serde_json::json!({"cmd": "conversation-attachment-read", "id": "m16", "conversation": CHIEF, "hash": "ab",
                "offset": 0, "length": 2097152}),
            serde_json::json!({"protocol": "cmux.protocol/2", "type": "request", "id": "m17", "operation": "chief.engine.get",
                "params": {"machine": "current", "session": "current"}}),
            serde_json::json!({"protocol": "cmux.protocol/2", "type": "request", "id": "m18", "operation": "chief.engine.set",
                "params": {"machine": "current", "session": "current", "model": "opus", "effort": "high"},
                "idempotency_key": "cmux-next-ios-chief-engine-1"}),
            serde_json::json!({"protocol": "cmux.protocol/2", "type": "request", "id": "m19", "operation": "chief.stop",
                "params": {"machine": "current", "session": "current"}, "idempotency_key": "cmux-next-ios-chief-stop-1"}),
        ] {
            assert_eq!(policy.evaluate(&line(value.clone())), Verdict::Forward, "{value}");
        }
    }

    #[test]
    fn conversations_outside_the_scope_are_refused() {
        let policy = listed();
        // Never listed, or listed but with another human (a paired install).
        for conversation in [REMOTE, "conv_01JNEVERLISTED0000000000000"] {
            refused(
                &policy,
                serde_json::json!({"cmd": "conversation-snapshot", "id": 1, "conversation": conversation, "tail": 1}),
            );
            refused(
                &policy,
                serde_json::json!({"cmd": "conversation-op", "id": 1, "conversation": conversation,
                "idempotency_key": "k", "op": {"kind": "read_cursor.set", "seq": 1}}),
            );
        }
        // Before any list, nothing is in scope.
        refused(
            &ChiefPolicy::new(),
            serde_json::json!({"cmd": "conversation-snapshot", "id": 1, "conversation": CHIEF, "tail": 1}),
        );
        // Ref forms and names are not ids.
        refused(
            &policy,
            serde_json::json!({"cmd": "conversation-snapshot", "id": 1, "conversation": "@1", "tail": 1}),
        );
    }

    #[test]
    fn unlisted_commands_ops_parts_and_command_params_are_refused() {
        let policy = listed();
        for value in [
            serde_json::json!({"cmd": "conversation-agent-token", "id": 1, "participant": "agent_mux"}),
            serde_json::json!({"cmd": "conversation-bind", "id": 1, "participant": "agent_mux", "token": "t"}),
            serde_json::json!({"cmd": "conversation-create", "id": 1, "idempotency_key": "k", "title": "x", "participants": []}),
            serde_json::json!({"cmd": "conversation-import", "id": 1, "conversation": CHIEF, "messages": []}),
            serde_json::json!({"cmd": "conversation-draft", "id": 1, "conversation": CHIEF}),
            serde_json::json!({"cmd": "chief-inspect", "id": 1, "path": "/api/status"}),
            serde_json::json!({"cmd": "cloud-inbox-list", "id": 1}),
            serde_json::json!({"cmd": "send", "id": 1, "surface": 1, "text": "id\n"}),
            serde_json::json!({"cmd": "new-tab", "id": 1, "command": "sh"}),
            serde_json::json!({"cmd": "conversation-snapshot", "id": 1, "conversation": CHIEF, "tail": 1, "command": "id"}),
            serde_json::json!({"cmd": "conversation-op", "id": 1, "conversation": CHIEF, "idempotency_key": "k", "actor": "agent_mux",
                "op": {"kind": "read_cursor.set", "seq": 1}}),
            serde_json::json!({"cmd": "conversation-op", "id": 1, "conversation": CHIEF, "idempotency_key": "k",
                "op": {"kind": "participants.add", "participant": {"id": "user_x", "kind": "human", "display_name": "x"}}}),
            serde_json::json!({"cmd": "conversation-op", "id": 1, "conversation": CHIEF, "idempotency_key": "k",
                "op": {"kind": "message.send", "client_msg_id": "k", "parts": [{"type": "work", "session": "s", "status": "done"}]}}),
            serde_json::json!({"cmd": "conversation-op", "id": 1, "conversation": CHIEF, "idempotency_key": "k",
                "op": {"kind": "message.send", "client_msg_id": "k", "answers": ["msg_01A"], "parts": [{"type": "text", "text": "x"}]}}),
            serde_json::json!({"cmd": "conversation-op", "id": 1, "conversation": CHIEF, "idempotency_key": "k",
                "op": {"kind": "message.send", "client_msg_id": "k", "parts": [{"type": "text", "text": "x", "command": "id"}]}}),
            serde_json::json!({"cmd": "conversation-op", "id": 1, "conversation": CHIEF, "idempotency_key": "k"}),
            serde_json::json!({"cmd": "conversation-attachment-upload", "id": 1, "op": "chunk", "upload": "u", "conversation": CHIEF}),
            serde_json::json!({"protocol": "cmux.protocol/2", "type": "request", "id": 1, "operation": "pane.run", "params": {}}),
            serde_json::json!({"protocol": "cmux.protocol/2", "type": "request", "id": 1, "operation": "chief.engine.set",
                "params": {"machine": "current", "session": "current", "model": "opus"}, "origin": {"token": "t"}}),
            serde_json::json!({"protocol": "cmux.protocol/2", "type": "request", "id": 1, "operation": "chief.engine.set",
                "params": {"machine": "mac-2", "session": "current", "model": "opus"}}),
            serde_json::json!({"protocol": "cmux.protocol/2", "type": "request", "id": 1, "operation": "chief.engine.set",
                "params": {"machine": "current", "session": "current", "command": "id"}}),
        ] {
            refused(&policy, value);
        }
    }

    #[test]
    fn events_reach_the_phone_only_in_scope() {
        let policy = listed();
        let event = |conversation: &str| {
            line(serde_json::json!({"event": "conversation-changed", "conversation": conversation, "rev": 2,
                "change": {"kind": "read-cursor", "participant": "agent_mux", "seq": 1}}))
        };
        assert!(policy.filter_reply(&event(CHIEF)).is_some());
        assert!(policy.filter_reply(&event(REMOTE)).is_none());
        // Non-conversation events from the owner daemon never pass.
        assert!(policy.filter_reply(br#"{"event":"terminal-registry-changed"}"#).is_none());
        assert!(policy.filter_reply(br#"{"event":"cloud-inbox-changed","entries":[]}"#).is_none());
        // A new owner-and-agents conversation joins the scope; a widened one leaves it.
        let new = "conv_01JNEW00000000000000000000";
        let announce = |participants: Value| {
            line(serde_json::json!({"event": "conversation-changed", "conversation": new, "rev": 1,
                "change": {"kind": "conversation", "conversation": {"id": new, "participants": participants}}}))
        };
        let own =
            serde_json::json!([{"id": "user_local", "kind": "human"}, {"id": "agent_mux", "kind": "agent"}]);
        assert!(policy.filter_reply(&announce(own)).is_some());
        assert_eq!(
            policy.evaluate(&line(
                serde_json::json!({"cmd": "conversation-snapshot", "id": 2, "conversation": new, "tail": 1})
            )),
            Verdict::Forward
        );
        let widened =
            serde_json::json!([{"id": "user_local", "kind": "human"}, {"id": "remote_x", "kind": "human"}]);
        assert!(policy.filter_reply(&announce(widened)).is_none());
        refused(
            &policy,
            serde_json::json!({"cmd": "conversation-snapshot", "id": 3, "conversation": new, "tail": 1}),
        );
    }

    #[test]
    fn search_hits_are_narrowed() {
        let policy = listed();
        assert_eq!(
            policy.evaluate(br#"{"cmd":"conversation-search","id":"s1","query":"x","limit":5}"#),
            Verdict::Forward
        );
        let reply = serde_json::json!({"id": "s1", "ok": true, "data": {"hits": [
            {"conversation": CHIEF, "seq": 1}, {"conversation": REMOTE, "seq": 2}]}});
        let narrowed: Value =
            serde_json::from_slice(&policy.filter_reply(reply.to_string().as_bytes()).unwrap()).unwrap();
        assert_eq!(narrowed["data"]["hits"].as_array().unwrap().len(), 1);
        // Other replies pass untouched.
        assert_eq!(policy.evaluate(br#"{"cmd":"ping","id":"m9"}"#), Verdict::Forward);
        let plain = br#"{"id":"m9","ok":true,"data":{}}"#;
        assert_eq!(policy.filter_reply(plain).unwrap(), plain.to_vec());
    }

    /// A reply is matched to one request: an id cannot wait twice, so a
    /// second list (or a ping) cannot take the narrowed list's place.
    #[test]
    fn ids_are_never_reused_while_waiting() {
        let policy = listed();
        assert_eq!(policy.evaluate(br#"{"cmd":"ping","id":7}"#), Verdict::Forward);
        assert!(matches!(policy.evaluate(br#"{"cmd":"conversation-list","id":7}"#), Verdict::Refuse(_)));
        assert!(matches!(policy.evaluate(br#"{"cmd":"conversation-list"}"#), Verdict::Refuse(_)));
        assert!(matches!(
            policy.evaluate(br#"{"cmd":"conversation-list","id":{"x":1}}"#),
            Verdict::Refuse(_)
        ));
        // The ping's reply frees the id; a reply nobody waits for is dropped.
        assert!(policy.filter_reply(br#"{"id":7,"ok":true,"data":{}}"#).is_some());
        assert!(policy.filter_reply(br#"{"id":7,"ok":true,"data":{"conversations":[]}}"#).is_none());
        assert_eq!(policy.evaluate(br#"{"cmd":"conversation-list","id":7}"#), Verdict::Forward);
        let unfiltered = serde_json::json!({"id": 7, "ok": true, "data": {"conversations": [
            {"id": REMOTE, "participants": [{"id": "user_local", "kind": "human"}, {"id": "remote_ab", "kind": "human"}]}]}});
        let narrowed: Value =
            serde_json::from_slice(&policy.filter_reply(unfiltered.to_string().as_bytes()).unwrap()).unwrap();
        assert!(narrowed["data"]["conversations"].as_array().unwrap().is_empty());
        // A new list replaces the scope: CHIEF is no longer listed.
        refused(
            &policy,
            serde_json::json!({"cmd": "conversation-snapshot", "id": 8, "conversation": CHIEF, "tail": 1}),
        );
        assert!(policy.filter_reply(br#"{"event":"overflow"}"#).is_some());
    }

    #[test]
    fn scope_rule() {
        let p = |v: Value| in_scope(&serde_json::json!({"participants": v}));
        assert!(p(
            serde_json::json!([{"id": "user_local", "kind": "human"}, {"id": "agent_mux", "kind": "agent"}])
        ));
        assert!(!p(serde_json::json!([{"id": "agent_mux", "kind": "agent"}])));
        assert!(!p(
            serde_json::json!([{"id": "user_local", "kind": "human"}, {"id": "user_2", "kind": "human"}])
        ));
        assert!(!p(
            serde_json::json!([{"id": "user_local", "kind": "human"}, {"id": "agent_mux", "kind": "human"}])
        ));
        assert!(!p(
            serde_json::json!([{"id": "user_local", "kind": "human"}, {"id": "agent_../x", "kind": "agent"}])
        ));
    }

    /// Home on the phone shows the Mac's Home list (`home-inbox`, local
    /// owner only) narrowed to the scope, and the person's own pin and
    /// unread mark of a Chief conversation in scope (`conversation-inbox-op`).
    #[test]
    fn home_inbox_and_list_state_stay_in_scope() {
        let policy = listed();
        assert_eq!(
            policy.evaluate(&line(serde_json::json!({"cmd": "home-inbox", "id": "h1", "owners": ["local"]}))),
            Verdict::Forward
        );
        let reply = serde_json::json!({"id": "h1", "ok": true, "data": {"me": "user_local", "cloud": "not_asked", "rows": [
            {"id": OTHER, "owner": "local", "kind": "channel", "name": "Build", "unread": 1, "activity_at": "2026-10-21T10:00:00.000Z",
             "pinned": true, "marked_unread": false, "muted": false},
            {"id": REMOTE, "owner": "local", "kind": "direct", "name": "Phone", "unread": 3, "activity_at": "2026-10-21T09:00:00.000Z",
             "pinned": false, "marked_unread": false, "muted": false},
            {"id": CHIEF, "owner": "local", "kind": "chief", "name": "Chief", "unread": 0, "activity_at": "2026-10-21T08:00:00.000Z",
             "chief_state": "idle", "pinned": false, "marked_unread": false, "muted": false},
            {"id": "conv_01JCLOUD0000000000000000000", "owner": "cloud", "kind": "direct", "name": "user_x", "unread": 0,
             "activity_at": "2026-10-21T07:00:00.000Z", "pinned": false, "marked_unread": false, "muted": false},
        ]}});
        let narrowed: Value =
            serde_json::from_slice(&policy.filter_reply(reply.to_string().as_bytes()).unwrap()).unwrap();
        let ids: Vec<&str> =
            narrowed["data"]["rows"].as_array().unwrap().iter().map(|r| r["id"].as_str().unwrap()).collect();
        // The owner's order, only conversations between the owner and agents.
        assert_eq!(ids, [OTHER, CHIEF]);
        assert_eq!(narrowed["data"]["me"], "user_local");
        // The Cloud owner's rows are never asked for over the link.
        refused(&policy, serde_json::json!({"cmd": "home-inbox", "id": "h2"}));
        refused(&policy, serde_json::json!({"cmd": "home-inbox", "id": "h3", "owners": ["local", "cloud"]}));
        refused(&policy, serde_json::json!({"cmd": "home-inbox", "id": "h4", "owners": ["cloud"]}));
        refused(&policy, serde_json::json!({"cmd": "home-inbox", "id": "h5", "owners": "local"}));

        for op in [
            serde_json::json!({"kind": "inbox.pin", "pinned": true, "position": 1_790_000_000_000_u64}),
            serde_json::json!({"kind": "inbox.pin", "pinned": false}),
            serde_json::json!({"kind": "inbox.mark_unread", "unread": true}),
        ] {
            assert_eq!(
                policy.evaluate(&line(serde_json::json!({"cmd": "conversation-inbox-op", "id": format!("p{op}"),
                    "conversation": CHIEF, "op": op}))),
                Verdict::Forward,
                "{op}"
            );
        }
        for value in [
            // Out of scope, or no conversation.
            serde_json::json!({"cmd": "conversation-inbox-op", "id": "x1", "conversation": REMOTE,
                "op": {"kind": "inbox.pin", "pinned": true}}),
            serde_json::json!({"cmd": "conversation-inbox-op", "id": "x2", "op": {"kind": "inbox.pin", "pinned": true}}),
            // Mute is the Cloud owner's; unknown kinds and fields are refused.
            serde_json::json!({"cmd": "conversation-inbox-op", "id": "x3", "conversation": CHIEF,
                "op": {"kind": "inbox.mute", "muted": true}}),
            serde_json::json!({"cmd": "conversation-inbox-op", "id": "x4", "conversation": CHIEF,
                "op": {"kind": "inbox.pin", "pinned": true, "participant": "agent_mux"}}),
            serde_json::json!({"cmd": "conversation-inbox-op", "id": "x5", "conversation": CHIEF,
                "op": {"kind": "inbox.mark_unread", "unread": "yes"}}),
            serde_json::json!({"cmd": "conversation-inbox-op", "id": "x6", "conversation": CHIEF, "op": "inbox.pin"}),
            serde_json::json!({"cmd": "conversation-inbox-op", "id": "x7", "conversation": CHIEF,
                "op": {"kind": "inbox.pin", "pinned": true}, "actor": "agent_mux"}),
        ] {
            refused(&policy, value);
        }

        // The person's list state comes back as its event, in scope only.
        let changed = |conversation: &str, participant: &str| {
            line(serde_json::json!({"event": "conversation-inbox-changed", "conversation": conversation,
                "participant": participant, "pinned": true, "marked_unread": false}))
        };
        assert!(policy.filter_reply(&changed(CHIEF, "user_local")).is_some());
        assert!(policy.filter_reply(&changed(REMOTE, "user_local")).is_none());
        assert!(policy.filter_reply(&changed(CHIEF, "agent_mux")).is_none());
        let unnamed = line(serde_json::json!({"event": "conversation-inbox-changed", "conversation": CHIEF,
            "pinned": true, "marked_unread": false}));
        assert!(policy.filter_reply(&unnamed).is_none());

        // A row with no owner (an owner before Cloud rows) is local; it still needs the scope.
        assert_eq!(policy.evaluate(br#"{"cmd":"home-inbox","id":"h6","owners":["local"]}"#), Verdict::Forward);
        let reply = serde_json::json!({"id": "h6", "ok": true, "data": {"me": "user_local", "rows": [
            {"id": CHIEF, "kind": "chief", "name": "Chief", "unread": 0, "activity_at": "x", "pinned": false, "marked_unread": false},
            {"id": REMOTE, "kind": "direct", "name": "P", "unread": 0, "activity_at": "x", "pinned": false, "marked_unread": false},
        ]}});
        let narrowed: Value =
            serde_json::from_slice(&policy.filter_reply(reply.to_string().as_bytes()).unwrap()).unwrap();
        assert_eq!(narrowed["data"]["rows"].as_array().unwrap().len(), 1);

        // A new owner-and-agents conversation the owner announces joins the rows too.
        let new = "conv_01JNEWHOME0000000000000000";
        let announce = line(serde_json::json!({"event": "conversation-changed", "conversation": new, "rev": 1,
            "change": {"kind": "conversation", "conversation": {"id": new, "participants": [
                {"id": "user_local", "kind": "human"}, {"id": "agent_mux", "kind": "agent"}]}}}));
        assert!(policy.filter_reply(&announce).is_some());
        assert_eq!(policy.evaluate(br#"{"cmd":"home-inbox","id":"h7","owners":["local"]}"#), Verdict::Forward);
        let reply = serde_json::json!({"id": "h7", "ok": true, "data": {"me": "user_local", "rows": [
            {"id": new, "owner": "local", "kind": "chief", "name": "Chief 2", "unread": 1, "activity_at": "x",
             "pinned": false, "marked_unread": false}]}});
        let narrowed: Value =
            serde_json::from_slice(&policy.filter_reply(reply.to_string().as_bytes()).unwrap()).unwrap();
        assert_eq!(narrowed["data"]["rows"][0]["id"], new);
    }
}
