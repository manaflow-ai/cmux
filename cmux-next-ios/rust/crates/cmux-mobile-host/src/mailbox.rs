//! The reply mailbox (PROTOCOL.md "Reply mailbox",
//! `verify/notifications-trust.md`). When a phone cannot reach this Mac over
//! its link, it seals a notification reply to the Mac's box key, signs it with
//! its identity key and posts it to the backend, which hands it to this Mac's
//! signaling socket (`mailbox`). The backend never holds a key that opens it.
//!
//! A reply is applied only after every check, in this order; the first that
//! fails rejects it with its reason:
//!
//! 1. `unsealed`: it opens with this Mac's box key, sealed for this Mac, the
//!    phone the backend names as the sender, and the item's id;
//! 2. `not_paired`: that phone is on the Mac's paired list and not refused;
//! 3. `bad_signature`: its identity key signed the reply;
//! 4. `expired`: `expiresAt` is ahead of now and at most 600 s past both
//!    `issuedAt` and now (86400 s for `send` and `compose`, [`max_lifetime`]);
//! 5. `replayed`: its id and its nonce were never seen (kept on disk until
//!    they expire, so a restart forgets nothing that still counts). A repeat
//!    of a reply this Mac already settled answers that first outcome again
//!    (its ack was lost, or the link delivered it first), never a new one;
//! 6. `not_pending`: its question or permission still waits, its session or
//!    Chief conversation exists, its terminal notification is still in the
//!    ledger ([`Applier`]).
//!
//! A reply that could not be settled yet (the app has not handed hostd its
//! keys or paired list, a service is not reachable) is `unavailable`: it is
//! not spent and not acknowledged, so it stays queued and is tried again.
//! Every ack is signed by this Mac's identity key ([`ack_message`]), so the
//! backend cannot tell the phone a reply was applied when it was not.
//!
//! It is then applied as the same request a phone sends over its link,
//! through the same policies (`acpmux_policy`, `DaemonPolicy`, `ChiefPolicy`).
//! An Allow or an answer still needs the acpmux approval the phone signed
//! after Face ID: acpmux checks it again against its own nonce.
//!
//! Store and forward (`mailbox-send-v1`, PROTOCOL.md "Store and forward"): a
//! hub that holds items for hours numbers each phone's items (`seq`). hostd
//! keeps the highest settled `seq` per phone ([`MailboxCursor`], written after
//! the outcome is in the spent file and before the ack). An item at or under
//! its phone's cursor is never applied: it answers its first outcome from the
//! spent file, else `replayed`. A phone's items are applied in `seq` order; one
//! that cannot be settled yet holds that phone's later items back, unacked
//! ([`MailboxOrder`]). An item with no `seq` (an older hub) goes by its id alone.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};

use cmux_mobile_link::signaling::{MailboxItem, MailboxResult};
use futures_util::future::BoxFuture;
use serde_json::{Map, Value};
use tokio::sync::watch;

use crate::pairing::{DeviceTrust, MacIdentity};

/// The domain of a reply signature.
pub const DOMAIN: &str = "cmux-mobile-reply-v1";
/// The longest a reply stays valid, in seconds.
pub const MAX_LIFETIME: u64 = 600;
/// The longest a `send` or `compose` item stays valid, in seconds (store and forward).
pub const MAX_SEND_LIFETIME: u64 = 86_400;
/// How long a held item keeps its phone's later items back without being tried again
/// (hostd retries it every 30 s while its socket lives; a socket that closed lets go).
pub const HOLD_STALE: std::time::Duration = std::time::Duration::from_secs(90);

/// The longest an item of `kind` stays valid, in seconds.
pub fn max_lifetime(kind: &str) -> u64 {
    if matches!(kind, "send" | "compose") { MAX_SEND_LIFETIME } else { MAX_LIFETIME }
}
/// How far ahead of this Mac's clock a phone's clock may run (`expiresAt`).
pub const CLOCK_SKEW: u64 = 60;
/// The domain of an ack signature.
pub const ACK_DOMAIN: &str = "cmux-mobile-mailbox-ack-v1";
/// The longest text a reply carries, in bytes.
pub const MAX_TEXT_BYTES: usize = 4096;
/// The largest sealed box accepted (base64url characters), as the backend
/// (`MAX_MAILBOX_SEALED`): 32 of them stay under one WebSocket frame. A text
/// whose escaped form is larger is refused on the phone before it is posted.
pub const MAX_SEALED: usize = 16_384;
/// At most this many items are handled from one frame.
pub const MAX_ITEMS: usize = 32;

/// Why a reply was not applied (the ack's `reason`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Rejection {
    Unsealed,
    NotPaired,
    BadSignature,
    Expired,
    Replayed,
    NotPending,
    /// Malformed after it verified, or refused when applied (the detail is logged, not sent).
    Refused(String),
    /// Not settled yet (no keys or paired list from the app, a service out of
    /// reach): neither spent nor acknowledged, so it is tried again.
    Unavailable(String),
    /// A repeat of a reply already settled: its first outcome (`None` applied,
    /// else the first reason's code).
    Repeat(Option<String>),
}

impl Rejection {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Unsealed => "unsealed",
            Self::NotPaired => "not_paired",
            Self::BadSignature => "bad_signature",
            Self::Expired => "expired",
            Self::Replayed => "replayed",
            Self::NotPending => "not_pending",
            Self::Refused(_) => "refused",
            Self::Unavailable(_) => "unavailable",
            Self::Repeat(_) => "replayed",
        }
    }
}

/// What an ack's signature covers: the domain, this Mac, the reply's id,
/// `1` (applied) or `0`, and the reason's code (empty when applied).
pub fn ack_message(mac: &str, id: &str, applied: bool, reason: Option<&str>) -> Vec<u8> {
    crate::seal::joined(ACK_DOMAIN, &[mac, id, if applied { "1" } else { "0" }, reason.unwrap_or("")])
}

/// What a reply asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ActionKind {
    /// A question's single option.
    Option,
    /// A question's answers.
    Answers,
    /// A permission's allow option.
    Allow,
    /// A permission's or question's reject option.
    Deny,
    /// Text: a prompt to the session, a Chief message, terminal input.
    Text,
    /// A composer queue action (`compose`).
    Queue,
}

/// A composer queue action (`compose`): `_acpmux/queue_edit`, or
/// `_acpmux/queue_remove` for `remove`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueAction {
    /// `update`, `remove`, `send_now` or `move`.
    pub op: String,
    /// The queued prompt it changes.
    pub prompt_id: String,
    /// The new text (`update`).
    pub text: Option<String>,
    /// The new place, from 0 (`move`).
    pub index: Option<u64>,
}

/// What a reply names.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Target {
    pub session_id: Option<String>,
    pub permission_id: Option<String>,
    pub conversation_id: Option<String>,
    pub tab_id: Option<String>,
    pub notification_id: Option<String>,
}

/// A reply that passed checks 1 to 5.
#[derive(Debug, Clone, PartialEq)]
pub struct Reply {
    pub id: String,
    pub phone: String,
    /// The notification's kind: `question`, `permission`, `completed`,
    /// `failed`, `chief` or `terminal`.
    pub kind: String,
    pub target: Target,
    pub action: ActionKind,
    pub option_id: Option<String>,
    pub answers: Option<Value>,
    pub text: Option<String>,
    /// The acpmux `_meta` the phone signed after Face ID (an Allow or answers).
    pub approval: Option<Value>,
    /// Whether a prompt steers a running turn (`send`'s `steer`, default true).
    pub steer: bool,
    /// A `compose` item's queue action.
    pub queue: Option<QueueAction>,
    pub nonce: String,
    pub expires_at: u64,
}

/// The signed bytes: the domain, the Mac, the phone and the lowercase hex
/// SHA-256 of the reply's canonical JSON without `sig`.
pub fn signed_message(mac: &str, phone: &str, unsigned: &Value) -> Vec<u8> {
    let mut canonical = String::new();
    crate::chief_answers::canonical_json(unsigned, &mut canonical);
    crate::seal::joined(DOMAIN, &[mac, phone, &crate::seal::sha256_hex(canonical.as_bytes())])
}

/// A spent key: until when it counts, and the reply's outcome once settled
/// (`Some("applied")` or a reason's code; `None` while it is being applied).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
struct Spent {
    until: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    outcome: Option<String>,
    /// Claimed and not settled yet (being applied). Not kept on disk: after a
    /// restart such a reply counts as seen with no outcome.
    #[serde(skip)]
    pending: bool,
}

/// What [`SpentReplies::claim`] found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Claim {
    /// Never seen: claimed now; settle or release it.
    Fresh,
    /// Seen and settled: its outcome (`applied` or a reason's code).
    Settled(String),
    /// Seen, with no outcome to repeat: another copy is being applied now, or
    /// another reply already used the nonce, or the record predates outcomes.
    Seen { in_progress: bool },
    /// The store on disk could not be read: nothing is applied (fail closed).
    Unreadable,
}

/// Replies and nonces already seen, until they expire, with each reply's
/// outcome. Shared by every signaling socket of this hostd, and kept on disk.
/// A store that exists but cannot be read refuses every reply until hostd
/// restarts with a readable one (a reply applied twice is worse than one not
/// applied).
#[derive(Debug, Default)]
pub struct SpentReplies {
    path: Option<PathBuf>,
    unreadable: bool,
    spent: Mutex<HashMap<String, Spent>>,
}

impl SpentReplies {
    pub fn memory() -> Self {
        Self::default()
    }

    pub fn load(path: PathBuf) -> Self {
        let (spent, unreadable) = match std::fs::read(&path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (HashMap::new(), false),
            Err(error) => {
                tracing::error!(%error, "the spent mailbox replies cannot be read: no reply is applied");
                (HashMap::new(), true)
            }
            Ok(bytes) => match Self::parse(&bytes) {
                Some(spent) => (spent, false),
                None => {
                    tracing::error!("the spent mailbox replies are unreadable: no reply is applied");
                    (HashMap::new(), true)
                }
            },
        };
        Self { path: Some(path), unreadable, spent: Mutex::new(spent) }
    }

    /// The file: `{key: {until, outcome?}}`, or the older `{key: until}`.
    fn parse(bytes: &[u8]) -> Option<HashMap<String, Spent>> {
        if let Ok(spent) = serde_json::from_slice::<HashMap<String, Spent>>(bytes) {
            return Some(spent);
        }
        let old = serde_json::from_slice::<HashMap<String, u64>>(bytes).ok()?;
        Some(old.into_iter().map(|(k, until)| (k, Spent { until, outcome: None, pending: false })).collect())
    }

    fn keys(id: &str, phone: &str, nonce: &str) -> Vec<String> {
        vec![format!("id:{id}"), format!("nonce:{phone}:{nonce}")]
    }

    /// Claims a mailbox reply's id and nonce until `expires`.
    pub fn claim(&self, id: &str, phone: &str, nonce: &str, expires: u64, now: u64) -> Claim {
        self.claim_keys(Self::keys(id, phone, nonce), expires, now)
    }

    /// Claims a reply that came over a link (`notification-reply` with
    /// `reply_id`): the same id the mailbox copy carries, so whichever comes
    /// second is not applied again.
    pub fn claim_link_reply(&self, id: &str, now: u64) -> Claim {
        self.claim_keys(vec![format!("id:{id}")], now + MAX_LIFETIME + CLOCK_SKEW, now)
    }

    /// What the store knows of a reply id, without claiming it: `Settled` with
    /// its first outcome, `Seen` when it has none, `Fresh` when it holds no record.
    pub fn recorded(&self, id: &str, now: u64) -> Claim {
        if self.unreadable {
            return Claim::Unreadable;
        }
        let spent = self.spent.lock().unwrap_or_else(PoisonError::into_inner);
        match spent.get(&format!("id:{id}")).filter(|entry| entry.until >= now) {
            Some(Spent { outcome: Some(outcome), .. }) => Claim::Settled(outcome.clone()),
            Some(Spent { pending, .. }) => Claim::Seen { in_progress: *pending },
            None => Claim::Fresh,
        }
    }

    /// Records the outcome of a claimed reply (`None`: applied).
    pub fn settle(&self, id: &str, outcome: Option<&str>) {
        let mut spent = self.spent.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(entry) = spent.get_mut(&format!("id:{id}")) {
            entry.outcome = Some(outcome.unwrap_or("applied").to_owned());
            entry.pending = false;
        }
        let _ = self.save(&spent);
    }

    /// Gives a claimed reply back (it could not be settled): a later copy is applied.
    pub fn release(&self, id: &str, phone: &str, nonce: &str) {
        let mut spent = self.spent.lock().unwrap_or_else(PoisonError::into_inner);
        for key in Self::keys(id, phone, nonce) {
            spent.remove(&key);
        }
        let _ = self.save(&spent);
    }

    /// Gives a claimed link reply back.
    pub fn release_link_reply(&self, id: &str) {
        let mut spent = self.spent.lock().unwrap_or_else(PoisonError::into_inner);
        spent.remove(&format!("id:{id}"));
        let _ = self.save(&spent);
    }

    fn claim_keys(&self, keys: Vec<String>, expires: u64, now: u64) -> Claim {
        if self.unreadable {
            return Claim::Unreadable;
        }
        let mut spent = self.spent.lock().unwrap_or_else(PoisonError::into_inner);
        spent.retain(|_, entry| entry.until >= now);
        if keys.iter().any(|k| spent.contains_key(k)) {
            // The id's record holds its outcome; a nonce another reply already
            // used is a replay with no outcome of its own.
            return match spent.get(&keys[0]) {
                Some(Spent { outcome: Some(outcome), .. }) => Claim::Settled(outcome.clone()),
                Some(Spent { outcome: None, pending, .. }) => Claim::Seen { in_progress: *pending },
                None => Claim::Seen { in_progress: false },
            };
        }
        for key in &keys {
            spent.insert(key.clone(), Spent { until: expires, outcome: None, pending: true });
        }
        // A claim the store could not write is not applied: a restart would forget it
        // (review 2, N3).
        if !self.save(&spent) {
            for key in &keys {
                spent.remove(key);
            }
            return Claim::Unreadable;
        }
        Claim::Fresh
    }

    /// Writes the store; false when it could not.
    fn save(&self, spent: &HashMap<String, Spent>) -> bool {
        if let Some(path) = &self.path
            && let Err(error) =
                crate::push_keys::write_private(path, &serde_json::to_vec(spent).unwrap_or_default())
        {
            tracing::warn!(%error, "could not save spent mailbox replies");
            return false;
        }
        true
    }
}

/// Checks 1 to 4 for one item, then claims it (check 5): a fresh reply
/// comes back claimed, to be settled or released by the caller.
pub fn check(
    item: &MailboxItem,
    mac: &str,
    identity: &MacIdentity,
    trust: &DeviceTrust,
    spent: &SpentReplies,
    now: u64,
) -> Result<Reply, Rejection> {
    let reply = verify(item, mac, identity, trust, now)?;
    claim(&reply, spent, now)?;
    Ok(reply)
}

/// Check 5: claims a verified reply's id and nonce, or answers why not.
pub fn claim(reply: &Reply, spent: &SpentReplies, now: u64) -> Result<(), Rejection> {
    match spent.claim(&reply.id, &reply.phone, &reply.nonce, reply.expires_at, now) {
        Claim::Fresh => Ok(()),
        Claim::Settled(outcome) => Err(Rejection::Repeat((outcome != "applied").then_some(outcome))),
        Claim::Seen { in_progress: true } => {
            Err(Rejection::Unavailable("another copy is being applied".into()))
        }
        Claim::Seen { in_progress: false } => Err(Rejection::Replayed),
        Claim::Unreadable => Err(Rejection::Unavailable("the spent replies cannot be read".into())),
    }
}

/// An item at or under its phone's cursor: never applied again. Its first
/// outcome from the spent file (signed by the caller), else `replayed`.
pub fn behind_cursor(reply: &Reply, spent: &SpentReplies, now: u64) -> Rejection {
    match spent.recorded(&reply.id, now) {
        Claim::Settled(outcome) => Rejection::Repeat((outcome != "applied").then_some(outcome)),
        Claim::Unreadable => Rejection::Unavailable("the spent replies cannot be read".into()),
        Claim::Seen { in_progress: true } => Rejection::Unavailable("another copy is being applied".into()),
        Claim::Seen { in_progress: false } | Claim::Fresh => Rejection::Replayed,
    }
}

/// Checks 1 to 4 for one item, and its fields for its kind: the reply it carries.
pub fn verify(
    item: &MailboxItem,
    mac: &str,
    identity: &MacIdentity,
    trust: &DeviceTrust,
    now: u64,
) -> Result<Reply, Rejection> {
    // 1. It opens, for this Mac, this sender and this id.
    if item.sealed.len() > MAX_SEALED {
        return Err(Rejection::Unsealed);
    }
    let context = crate::seal::reply_context(mac, &item.from, &item.id);
    let plain =
        crate::seal::open(identity.box_secret(), &context, &item.sealed).map_err(|_| Rejection::Unsealed)?;
    let Ok(Value::Object(mut object)) = serde_json::from_slice::<Value>(&plain) else {
        return Err(Rejection::Unsealed);
    };
    let text = |o: &Map<String, Value>, k: &str| o.get(k).and_then(Value::as_str).map(str::to_owned);
    if object.get("v").and_then(Value::as_u64) != Some(1)
        || text(&object, "mac").as_deref() != Some(mac)
        || text(&object, "id").as_deref() != Some(item.id.as_str())
        || text(&object, "phone").as_deref() != Some(item.from.as_str())
    {
        return Err(Rejection::Unsealed);
    }
    // 2. A phone this Mac pairs now, and has not refused.
    let phone = item.from.as_str();
    let Some(device) = trust.devices.iter().find(|d| d.id == phone) else { return Err(Rejection::NotPaired) };
    if trust.denied.iter().any(|d| d.id == phone && d.identity_key == device.identity_key) {
        return Err(Rejection::NotPaired);
    }
    // 3. Its identity key signed it.
    let Some(Value::String(signature)) = object.remove("sig") else { return Err(Rejection::BadSignature) };
    let unsigned = Value::Object(object.clone());
    if !crate::pairing::verify(&device.identity_key, &signed_message(mac, phone, &unsigned), &signature) {
        return Err(Rejection::BadSignature);
    }
    // 4. Not expired, and never valid for long (a held send up to a day).
    let issued = object.get("issuedAt").and_then(Value::as_u64).ok_or(Rejection::Expired)?;
    let expires = object.get("expiresAt").and_then(Value::as_u64).ok_or(Rejection::Expired)?;
    let lifetime = max_lifetime(object.get("kind").and_then(Value::as_str).unwrap_or_default());
    if expires <= now || expires > issued.saturating_add(lifetime) || expires > now + lifetime + CLOCK_SKEW {
        return Err(Rejection::Expired);
    }
    parse(&object, item, expires).map_err(Rejection::Refused)
}

/// A target or queue id: 1 to 128 characters, no control characters.
fn is_id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 128 && s.chars().all(|c| !c.is_control())
}

/// The reply's fields, checked for its kind.
fn parse(object: &Map<String, Value>, item: &MailboxItem, expires: u64) -> Result<Reply, String> {
    let nonce = object.get("nonce").and_then(Value::as_str).unwrap_or_default();
    if !(16..=128).contains(&nonce.len()) || !nonce.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err("nonce is 16 to 128 letters or digits".into());
    }
    let kind = object.get("kind").and_then(Value::as_str).unwrap_or_default().to_owned();
    let target_object = object.get("target").and_then(Value::as_object).ok_or("no target")?;
    let field = |k: &str| -> Result<Option<String>, String> {
        match target_object.get(k) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(s)) if is_id(s) => Ok(Some(s.clone())),
            Some(_) => Err(format!("target.{k} is not an id")),
        }
    };
    let target = Target {
        session_id: field("sessionId")?,
        permission_id: field("permissionId")?,
        conversation_id: field("conversationId")?,
        tab_id: field("tabId")?,
        notification_id: field("notificationId")?,
    };
    let action_object = object.get("action").and_then(Value::as_object).ok_or("no action")?;
    let action = match action_object.get("type").and_then(Value::as_str) {
        Some("option") => ActionKind::Option,
        Some("answers") => ActionKind::Answers,
        Some("allow") => ActionKind::Allow,
        Some("deny") => ActionKind::Deny,
        Some("text") => ActionKind::Text,
        Some("queue") => ActionKind::Queue,
        _ => return Err("unknown action".into()),
    };
    let option_id = action_object.get("optionId").and_then(Value::as_str).map(str::to_owned);
    let answers = action_object.get("answers").filter(|a| !a.is_null()).cloned();
    let text = action_object.get("text").and_then(Value::as_str).map(str::to_owned);
    let approval = object.get("approval").filter(|a| !a.is_null()).cloned();
    let needs = |ok: bool, what: &str| if ok { Ok(()) } else { Err(format!("{kind} needs {what}")) };
    let steer = match action_object.get("steer") {
        None | Some(Value::Null) => true,
        Some(Value::Bool(steer)) => *steer,
        Some(_) => return Err("steer is true or false".into()),
    };
    let mut queue = None;
    match kind.as_str() {
        "question" | "permission" => {
            needs(
                target.session_id.is_some() && target.permission_id.is_some(),
                "a session and a permission",
            )?;
            needs(action != ActionKind::Text, "an option")?;
            // A deny with no option takes the prompt's own reject (a trimmed push carries none).
            needs(option_id.is_some() || action == ActionKind::Deny, "an option id")?;
            needs(action != ActionKind::Answers || answers.is_some(), "answers")?;
        }
        "completed" | "failed" => {
            needs(target.session_id.is_some(), "a session")?;
            needs(action == ActionKind::Text, "text")?;
        }
        "send" => {
            needs(target.session_id.is_some(), "a session")?;
            needs(action == ActionKind::Text, "text")?;
        }
        "compose" => {
            needs(target.session_id.is_some(), "a session")?;
            needs(action == ActionKind::Queue, "a queue action")?;
            queue = Some(queue_action(action_object)?);
        }
        "chief" => {
            needs(target.conversation_id.is_some(), "a conversation")?;
            needs(action == ActionKind::Text, "text")?;
        }
        "terminal" => {
            needs(terminal_surface(target.tab_id.as_deref()).is_some(), "a terminal tab")?;
            needs(
                target.notification_id.as_deref().is_some_and(|n| n.parse::<u64>().is_ok()),
                "a notification",
            )?;
            needs(action == ActionKind::Text, "text")?;
        }
        _ => return Err("unknown kind".into()),
    }
    if action == ActionKind::Text {
        let t = text.as_deref().unwrap_or_default();
        if t.trim().is_empty() || t.len() > MAX_TEXT_BYTES {
            return Err(format!("text is 1 to {MAX_TEXT_BYTES} bytes"));
        }
    }
    Ok(Reply {
        id: item.id.clone(),
        phone: item.from.clone(),
        kind,
        target,
        action,
        option_id,
        answers,
        text,
        approval,
        steer,
        queue,
        nonce: nonce.to_owned(),
        expires_at: expires,
    })
}

/// A `compose` item's `action`: `{type: "queue", op, promptId, text?, index?}`.
fn queue_action(action: &Map<String, Value>) -> Result<QueueAction, String> {
    let op = action.get("op").and_then(Value::as_str).unwrap_or_default();
    if !matches!(op, "update" | "remove" | "send_now" | "move") {
        return Err("op is update, remove, send_now or move".into());
    }
    let prompt_id = action.get("promptId").and_then(Value::as_str).filter(|p| is_id(p));
    let prompt_id = prompt_id.ok_or("compose needs a promptId")?.to_owned();
    let text = action.get("text").and_then(Value::as_str).map(str::to_owned);
    let index = action.get("index").and_then(Value::as_u64);
    match op {
        "update" => {
            let t = text.as_deref().unwrap_or_default();
            if t.trim().is_empty() || t.len() > MAX_TEXT_BYTES {
                return Err(format!("update text is 1 to {MAX_TEXT_BYTES} bytes"));
            }
        }
        "move" if index.is_none() => return Err("move needs an index from 0".into()),
        _ => {}
    }
    let keep_text = op == "update";
    Ok(QueueAction {
        op: op.to_owned(),
        prompt_id,
        text: text.filter(|_| keep_text),
        index: index.filter(|_| op == "move"),
    })
}

/// The surface of a terminal tab id (`s<surface>`).
pub fn terminal_surface(tab: Option<&str>) -> Option<u64> {
    tab?.strip_prefix('s')?.parse().ok()
}

/// Check 6 and the application: the services a link would reach.
pub trait Applier: Send + Sync {
    /// Applies `reply` if its target still waits; `NotPending` if not, `Refused` if a service refused it.
    fn apply<'a>(&'a self, reply: &'a Reply) -> BoxFuture<'a, Result<(), Rejection>>;
}

/// The highest settled `seq` per phone, kept on disk (`mailbox-cursor.json`,
/// 0600). Like [`SpentReplies`], a file that exists but cannot be read applies
/// nothing until hostd restarts with a readable one.
#[derive(Debug, Default)]
pub struct MailboxCursor {
    path: Option<PathBuf>,
    unreadable: bool,
    cursor: Mutex<HashMap<String, u64>>,
}

impl MailboxCursor {
    pub fn memory() -> Self {
        Self::default()
    }

    pub fn load(path: PathBuf) -> Self {
        let (cursor, unreadable) = match std::fs::read(&path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (HashMap::new(), false),
            Err(error) => {
                tracing::error!(%error, "the mailbox cursor cannot be read: no mailbox item is applied");
                (HashMap::new(), true)
            }
            Ok(bytes) => match serde_json::from_slice::<HashMap<String, u64>>(&bytes) {
                Ok(cursor) => (cursor, false),
                Err(_) => {
                    tracing::error!("the mailbox cursor is unreadable: no mailbox item is applied");
                    (HashMap::new(), true)
                }
            },
        };
        Self { path: Some(path), unreadable, cursor: Mutex::new(cursor) }
    }

    /// Whether the file could be read (else nothing is applied).
    pub fn readable(&self) -> bool {
        !self.unreadable
    }

    /// The phone's highest settled `seq` (0: none yet); `None` when the file is unreadable.
    pub fn get(&self, phone: &str) -> Option<u64> {
        if self.unreadable {
            return None;
        }
        Some(self.cursor.lock().unwrap_or_else(PoisonError::into_inner).get(phone).copied().unwrap_or(0))
    }

    /// Moves the phone's cursor up to `seq` (never down) and writes it; false when
    /// it could not be written (the spent file still keeps the item from applying twice).
    pub fn advance(&self, phone: &str, seq: u64) -> bool {
        if self.unreadable {
            return false;
        }
        let mut cursor = self.cursor.lock().unwrap_or_else(PoisonError::into_inner);
        let at = cursor.entry(phone.to_owned()).or_insert(0);
        if *at >= seq {
            return true;
        }
        *at = seq;
        if let Some(path) = &self.path
            && let Err(error) =
                crate::push_keys::write_private(path, &serde_json::to_vec(&*cursor).unwrap_or_default())
        {
            tracing::warn!(%error, "could not save the mailbox cursor");
            return false;
        }
        true
    }
}

/// Each phone's item that could not be settled yet: it holds that phone's later
/// items back. Shared by every frame of this hostd, so a later frame never
/// overtakes a held item. A hold not tried again for [`HOLD_STALE`] (its socket
/// closed) lets go; the next delivery brings the held item again first.
#[derive(Debug, Default)]
pub struct MailboxOrder {
    held: Mutex<HashMap<String, (u64, std::time::Instant)>>,
    /// One frame at a time: two frames handled at once could apply a phone's
    /// later item before its earlier one settles.
    turn: tokio::sync::Mutex<()>,
}

impl MailboxOrder {
    /// Whether `seq` of `phone` waits for an earlier held item.
    fn blocked(&self, phone: &str, seq: u64) -> bool {
        let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        held.get(phone).is_some_and(|(first, at)| *first < seq && at.elapsed() < HOLD_STALE)
    }

    /// `seq` of `phone` could not be settled: it holds the later ones.
    fn hold(&self, phone: &str, seq: u64) {
        let mut held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        let now = std::time::Instant::now();
        let entry = held.entry(phone.to_owned()).or_insert((seq, now));
        if seq <= entry.0 || entry.1.elapsed() >= HOLD_STALE {
            *entry = (seq, now);
        }
    }

    /// `seq` of `phone` settled: a hold it made lets go.
    fn settled(&self, phone: &str, seq: u64) {
        let mut held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        if held.get(phone).is_some_and(|(first, _)| *first <= seq) {
            held.remove(phone);
        }
    }
}

/// Everything one hostd needs to answer mailbox frames.
pub struct Mailbox {
    pub mac: String,
    pub trust: watch::Receiver<Option<DeviceTrust>>,
    pub identity: watch::Receiver<Option<MacIdentity>>,
    /// Shared with the links (`Pairing::spent_replies`).
    pub spent: Arc<SpentReplies>,
    /// The highest settled `seq` per phone (`Pairing::mailbox_cursor`).
    pub cursor: Arc<MailboxCursor>,
    /// Each phone's held item, across frames.
    pub order: MailboxOrder,
    pub applier: Arc<dyn Applier>,
    /// How long an item waits for the app's keys and paired list (`TRUST_WAIT`).
    pub key_wait: std::time::Duration,
}

impl Mailbox {
    /// Checks and applies each item: those with no `seq` in frame order, then
    /// each phone's in `seq` order. Settled items get a signed result; the rest
    /// (`unavailable`, and a phone's items after its first held one) are
    /// returned to try again, unacked.
    pub async fn handle(&self, items: Vec<MailboxItem>, now: u64) -> Handled {
        let _turn = self.order.turn.lock().await;
        let mut handled = Handled::default();
        let mut plain = Vec::new();
        let mut queues: std::collections::BTreeMap<String, Vec<MailboxItem>> = Default::default();
        for item in items.into_iter().take(MAX_ITEMS) {
            match item.seq {
                Some(_) => queues.entry(item.from.clone()).or_default().push(item),
                None => plain.push(item),
            }
        }
        for queue in queues.values_mut() {
            queue.sort_by_key(|item| item.seq);
        }
        let ordered = plain.into_iter().chain(queues.into_values().flatten());
        for item in ordered {
            if let Some(seq) = item.seq
                && self.order.blocked(&item.from, seq)
            {
                tracing::info!(id = item.id, seq, "mailbox item waits for its phone's earlier one");
                handled.later.push(item);
                continue;
            }
            let outcome = self.handle_one(&item, now).await;
            let (applied, reason) = match &outcome {
                Ok(()) => (true, None),
                Err(Rejection::Unavailable(why)) => {
                    tracing::info!(id = item.id, why, "mailbox reply not settled yet");
                    if let Some(seq) = item.seq {
                        self.order.hold(&item.from, seq);
                    }
                    handled.later.push(item);
                    continue;
                }
                Err(Rejection::Repeat(first)) => {
                    // A copy of a settled reply: nothing is applied again; its first outcome is
                    // answered (signed) so a lost ack never reads as a failure.
                    tracing::info!(id = item.id, first = ?first, "mailbox reply repeated: not applied again");
                    (first.is_none(), first.clone())
                }
                Err(rejection) => (false, Some(rejection.code().to_owned())),
            };
            if let Some(seq) = item.seq {
                self.order.settled(&item.from, seq);
            }
            if applied {
                tracing::info!(id = item.id, "mailbox reply applied");
            } else {
                tracing::info!(id = item.id, reason = ?outcome, "mailbox reply rejected");
            }
            let identity = self.identity.borrow().clone();
            let sig =
                identity.and_then(|i| i.sign(&ack_message(&self.mac, &item.id, applied, reason.as_deref())));
            handled.results.push(MailboxResult { id: item.id, applied, reason, sig });
        }
        handled
    }

    async fn handle_one(&self, item: &MailboxItem, now: u64) -> Result<(), Rejection> {
        // A hostd that just started waits for the app's keys and paired list, as `auth` does.
        let identity = Self::loaded(self.identity.clone(), self.key_wait)
            .await
            .ok_or_else(|| Rejection::Unavailable("the Mac app has not sent its identity key".into()))?;
        let trust = Self::loaded(self.trust.clone(), self.key_wait)
            .await
            .ok_or_else(|| Rejection::Unavailable("the Mac app has not sent its paired iPhones".into()))?;
        // As with the spent file: a cursor that cannot be read applies nothing.
        if !self.cursor.readable() {
            return Err(Rejection::Unavailable("the mailbox cursor cannot be read".into()));
        }
        let reply = verify(item, &self.mac, &identity, &trust, now)?;
        // At or under the phone's cursor: settled before (its ack was lost, the hub sent it
        // again): never applied again.
        let cursor = self.cursor.get(&reply.phone).unwrap_or(u64::MAX);
        let outcome = match item.seq {
            Some(seq) if seq <= cursor => Err(behind_cursor(&reply, &self.spent, now)),
            _ => match claim(&reply, &self.spent, now) {
                Err(rejection) => Err(rejection),
                Ok(()) => {
                    let outcome = self.applier.apply(&reply).await;
                    match &outcome {
                        Err(Rejection::Unavailable(_)) => {
                            self.spent.release(&reply.id, &reply.phone, &reply.nonce);
                        }
                        Ok(()) => self.spent.settle(&reply.id, None),
                        Err(rejection) => self.spent.settle(&reply.id, Some(rejection.code())),
                    }
                    outcome
                }
            },
        };
        // Settled (its outcome is in the spent file): the cursor moves up before the ack.
        if let Some(seq) = item.seq
            && !matches!(outcome, Err(Rejection::Unavailable(_)))
        {
            self.cursor.advance(&reply.phone, seq);
        }
        outcome
    }

    async fn loaded<T: Clone>(
        mut receiver: watch::Receiver<Option<T>>,
        wait: std::time::Duration,
    ) -> Option<T> {
        let ready = async { receiver.wait_for(Option::is_some).await.ok().and_then(|v| v.clone()) };
        tokio::time::timeout(wait, ready).await.ok().flatten()
    }
}

/// What one mailbox frame came to.
#[derive(Debug, Default, PartialEq)]
pub struct Handled {
    /// One signed result per settled item, in order.
    pub results: Vec<MailboxResult>,
    /// Items that could not be settled yet: tried again, never acknowledged until settled.
    pub later: Vec<MailboxItem>,
}

/// Now, in Unix seconds.
pub fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pairing::{DeniedDevice, TrustedDevice};
    use serde_json::json;

    const MAC: &str = "6f1c2a7e-0b1d-4c55-9a43-2d8e5b7f3c10";
    const PHONE: &str = "a2b4c6d8-1e3f-4a5b-8c7d-9e0f1a2b3c4d";
    const NOW: u64 = 1_792_540_900;

    fn vectors() -> Value {
        serde_json::from_str(include_str!("../tests/fixtures/seal-vectors.json")).unwrap()
    }

    fn mac_identity() -> MacIdentity {
        let v = vectors();
        MacIdentity::from_raw(v["macIdentityScalar"].as_str().unwrap(), v["macIdentityKey"].as_str().unwrap())
            .unwrap()
    }

    /// The phone's identity key from the vectors, as ring signs with it.
    fn phone_signer() -> MacIdentity {
        let v = vectors();
        MacIdentity::from_raw(
            v["phoneIdentityScalar"].as_str().unwrap(),
            v["phoneIdentityKey"].as_str().unwrap(),
        )
        .unwrap()
    }

    fn trust() -> DeviceTrust {
        DeviceTrust {
            devices: vec![TrustedDevice {
                id: PHONE.into(),
                identity_key: vectors()["phoneIdentityKey"].as_str().unwrap().into(),
                approval_key: String::new(),
                ..Default::default()
            }],
            denied: vec![],
        }
    }

    /// A reply signed by the phone and sealed to the Mac, as the phone makes it.
    fn sealed(mut reply: Value, signer: &MacIdentity) -> MailboxItem {
        let id = reply["id"].as_str().unwrap().to_owned();
        let from = reply["phone"].as_str().unwrap().to_owned();
        let mac = reply["mac"].as_str().unwrap().to_owned();
        let signature = signer.sign(&signed_message(&mac, &from, &reply)).unwrap();
        reply["sig"] = json!(signature);
        let boxed = crate::seal::seal(
            &mac_identity().box_secret().public_key(),
            &crate::seal::reply_context(&mac, &from, &id),
            reply.to_string().as_bytes(),
        )
        .unwrap();
        MailboxItem { id, from, sealed: boxed, at: None, seq: None }
    }

    fn text_reply(id: &str) -> Value {
        json!({"v": 1, "id": id, "mac": MAC, "phone": PHONE, "kind": "completed",
               "target": {"sessionId": "s1"}, "action": {"type": "text", "text": "ship it"},
               "nonce": format!("nonce{id}0123456789abcdef").replace('-', ""),
               "issuedAt": NOW - 10, "expiresAt": NOW + 290})
    }

    fn checked(item: &MailboxItem, spent: &SpentReplies) -> Result<Reply, Rejection> {
        check(item, MAC, &mac_identity(), &trust(), spent, NOW)
    }

    #[test]
    fn the_vector_reply_opens_and_verifies() {
        let v = vectors();
        let item = MailboxItem {
            id: v["reply"]["id"].as_str().unwrap().into(),
            from: PHONE.into(),
            sealed: v["reply"]["box"].as_str().unwrap().into(),
            at: None,
            seq: None,
        };
        // The canonical form and digest agree with Python's.
        let mut unsigned: Value = serde_json::from_str(v["reply"]["plaintext"].as_str().unwrap()).unwrap();
        unsigned.as_object_mut().unwrap().remove("sig");
        let message = signed_message(MAC, PHONE, &unsigned);
        assert_eq!(crate::seal::hex(&message), v["reply"]["signatureMessage"].as_str().unwrap());
        let reply =
            check(&item, MAC, &mac_identity(), &trust(), &SpentReplies::memory(), 1_792_540_900).unwrap();
        assert_eq!(reply.kind, "completed");
        assert_eq!(reply.text.as_deref(), Some("ship it\n\"now\""));
        assert_eq!(reply.target.session_id.as_deref(), Some("s1"));
    }

    #[test]
    fn a_signed_sealed_reply_passes_once_and_a_repeat_answers_its_first_outcome() {
        let spent = SpentReplies::memory();
        let item = sealed(text_reply("r-1"), &phone_signer());
        assert!(checked(&item, &spent).is_ok());
        // Another copy while the first is still being applied: not settled, tried again.
        assert!(matches!(checked(&item, &spent), Err(Rejection::Unavailable(_))));
        spent.settle("r-1", None);
        assert_eq!(checked(&item, &spent), Err(Rejection::Repeat(None)));
        // A new id with the same nonce is a replay with no outcome of its own.
        let mut again = text_reply("r-2");
        again["nonce"] = text_reply("r-1")["nonce"].clone();
        assert_eq!(checked(&sealed(again, &phone_signer()), &spent), Err(Rejection::Replayed));
        // A refused reply repeats its refusal, never an "applied".
        let refused = sealed(text_reply("r-3"), &phone_signer());
        assert!(checked(&refused, &spent).is_ok());
        spent.settle("r-3", Some("not_pending"));
        assert_eq!(checked(&refused, &spent), Err(Rejection::Repeat(Some("not_pending".into()))));
        // A released claim (it could not be applied yet) passes again.
        let later = sealed(text_reply("r-4"), &phone_signer());
        let reply = checked(&later, &spent).unwrap();
        spent.release(&reply.id, &reply.phone, &reply.nonce);
        assert!(checked(&later, &spent).is_ok());
    }

    #[test]
    fn a_phone_clock_a_little_ahead_is_allowed() {
        let spent = SpentReplies::memory();
        let mut ahead = text_reply("skew-1");
        ahead["issuedAt"] = json!(NOW + 30);
        ahead["expiresAt"] = json!(NOW + 30 + MAX_LIFETIME);
        assert!(checked(&sealed(ahead, &phone_signer()), &spent).is_ok());
        let mut far = text_reply("skew-2");
        far["issuedAt"] = json!(NOW + CLOCK_SKEW + 1);
        far["expiresAt"] = json!(NOW + CLOCK_SKEW + 1 + MAX_LIFETIME);
        assert_eq!(checked(&sealed(far, &phone_signer()), &spent), Err(Rejection::Expired));
    }

    #[test]
    fn a_deny_may_leave_the_option_to_the_mac() {
        let mut deny = text_reply("deny-1");
        deny["kind"] = json!("permission");
        deny["target"] = json!({"sessionId": "s1", "permissionId": "p1"});
        deny["action"] = json!({"type": "deny"});
        let reply = checked(&sealed(deny, &phone_signer()), &SpentReplies::memory()).unwrap();
        assert_eq!((reply.action, reply.option_id), (ActionKind::Deny, None));
    }

    #[test]
    fn an_ack_is_signed_by_the_mac_identity_key() {
        let message = ack_message(MAC, "r-1", false, Some("not_pending"));
        assert_eq!(message, crate::seal::joined(ACK_DOMAIN, &[MAC, "r-1", "0", "not_pending"]));
        let signature = mac_identity().sign(&message).unwrap();
        assert!(crate::pairing::verify(mac_identity().public_key(), &message, &signature));
        assert!(!crate::pairing::verify(
            mac_identity().public_key(),
            &ack_message(MAC, "r-1", true, None),
            &signature
        ));
    }

    #[test]
    fn each_check_rejects_with_its_reason() {
        let spent = SpentReplies::memory();
        // 1. Sealed to another Mac's key, or the backend names another sender or id.
        let mut item = sealed(text_reply("r-3"), &phone_signer());
        let mut other = item.clone();
        other.from = "e1e2e3e4-0000-4000-8000-000000000000".into();
        assert_eq!(checked(&other, &spent), Err(Rejection::Unsealed));
        let mut other = item.clone();
        other.id = "r-other".into();
        assert_eq!(checked(&other, &spent), Err(Rejection::Unsealed));
        let stranger = MacIdentity::generate().unwrap();
        let foreign = crate::seal::seal(
            &stranger.box_secret().public_key(),
            &crate::seal::reply_context(MAC, PHONE, "r-3"),
            b"{}",
        )
        .unwrap();
        assert_eq!(
            checked(&MailboxItem { sealed: foreign, ..item.clone() }, &spent),
            Err(Rejection::Unsealed)
        );
        // 2. A phone the Mac does not pair, or refused.
        let mut unpaired = trust();
        unpaired.devices.clear();
        assert_eq!(check(&item, MAC, &mac_identity(), &unpaired, &spent, NOW), Err(Rejection::NotPaired));
        let mut refused = trust();
        refused
            .denied
            .push(DeniedDevice { id: PHONE.into(), identity_key: refused.devices[0].identity_key.clone() });
        assert_eq!(check(&item, MAC, &mac_identity(), &refused, &spent, NOW), Err(Rejection::NotPaired));
        // 3. Signed by another key, or changed after signing.
        let forged = sealed(text_reply("r-4"), &MacIdentity::generate().unwrap());
        assert_eq!(checked(&forged, &spent), Err(Rejection::BadSignature));
        // 4. Expired, or valid for too long.
        let mut late = text_reply("r-5");
        late["expiresAt"] = json!(NOW - 1);
        assert_eq!(checked(&sealed(late, &phone_signer()), &spent), Err(Rejection::Expired));
        let mut long = text_reply("r-6");
        long["issuedAt"] = json!(NOW);
        long["expiresAt"] = json!(NOW + MAX_LIFETIME + 1);
        assert_eq!(checked(&sealed(long, &phone_signer()), &spent), Err(Rejection::Expired));
        // None of the rejected ones were spent: the good one still passes once.
        assert!(checked(&item, &spent).is_ok());
        item.sealed.push('A');
        assert!(checked(&item, &spent).is_err());
    }

    #[test]
    fn a_reply_must_name_what_its_kind_needs() {
        let spent = SpentReplies::memory();
        let cases = [
            (
                json!({"kind": "permission", "target": {"sessionId": "s1"}, "action": {"type": "deny", "optionId": "no"}}),
                false,
            ),
            (
                json!({"kind": "permission", "target": {"sessionId": "s1", "permissionId": "p1"}, "action": {"type": "deny", "optionId": "no"}}),
                true,
            ),
            (
                json!({"kind": "question", "target": {"sessionId": "s1", "permissionId": "p1"}, "action": {"type": "answers", "optionId": "a"}}),
                false,
            ),
            (
                json!({"kind": "question", "target": {"sessionId": "s1", "permissionId": "p1"}, "action": {"type": "text", "text": "x"}}),
                false,
            ),
            (
                json!({"kind": "chief", "target": {"conversationId": "conv_A"}, "action": {"type": "text", "text": "hi"}}),
                true,
            ),
            (json!({"kind": "chief", "target": {}, "action": {"type": "text", "text": "hi"}}), false),
            (
                json!({"kind": "terminal", "target": {"tabId": "s7", "notificationId": "12"}, "action": {"type": "text", "text": "y"}}),
                true,
            ),
            (
                json!({"kind": "terminal", "target": {"tabId": "t7", "notificationId": "12"}, "action": {"type": "text", "text": "y"}}),
                false,
            ),
            (
                json!({"kind": "terminal", "target": {"tabId": "s7", "notificationId": "12"}, "action": {"type": "text", "text": "x".repeat(MAX_TEXT_BYTES + 1)}}),
                false,
            ),
            (
                json!({"kind": "completed", "target": {"sessionId": "s1"}, "action": {"type": "text", "text": "  "}}),
                false,
            ),
            (
                json!({"kind": "shell", "target": {"sessionId": "s1"}, "action": {"type": "text", "text": "ls"}}),
                false,
            ),
        ];
        for (index, (fields, ok)) in cases.into_iter().enumerate() {
            let mut reply = text_reply(&format!("k-{index}"));
            for (key, value) in fields.as_object().unwrap() {
                reply[key] = value.clone();
            }
            let result = checked(&sealed(reply, &phone_signer()), &spent);
            assert_eq!(result.is_ok(), ok, "case {index}: {result:?}");
            if !ok {
                assert!(matches!(result, Err(Rejection::Refused(_))), "case {index}: {result:?}");
            }
        }
    }

    #[test]
    fn spent_replies_and_outcomes_survive_a_restart_until_they_expire() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("mailbox-spent.json");
        let first = SpentReplies::load(path.clone());
        assert_eq!(first.claim("r", PHONE, "n", NOW + 60, NOW), Claim::Fresh);
        first.settle("r", None);
        let again = SpentReplies::load(path.clone());
        assert_eq!(again.claim("r", PHONE, "other", NOW + 60, NOW), Claim::Settled("applied".into()));
        assert_eq!(again.claim("other", PHONE, "n", NOW + 60, NOW), Claim::Seen { in_progress: false });
        // After its expiry the record is dropped (an expired reply fails check 4 anyway).
        assert_eq!(SpentReplies::load(path).claim("r", PHONE, "n", NOW + 600, NOW + 61), Claim::Fresh);
    }

    /// Review 2, N3: a claim the store could not write is not applied (a restart would
    /// forget it, and a kept copy could be replayed).
    #[test]
    fn a_claim_that_cannot_be_saved_is_not_applied() {
        let dir = tempfile::tempdir().unwrap();
        // A folder this user can read but not write: the store loads (empty), then can't save.
        use std::os::unix::fs::PermissionsExt as _;
        let locked = dir.path().join("locked");
        std::fs::create_dir(&locked).unwrap();
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o500)).unwrap();
        let spent = SpentReplies::load(locked.join("mailbox-spent.json"));
        assert_eq!(spent.claim("r", PHONE, "n", NOW + 60, NOW), Claim::Unreadable);
        assert_eq!(spent.claim_link_reply("r", NOW), Claim::Unreadable);
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn an_unreadable_spent_store_applies_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("mailbox-spent.json");
        std::fs::write(&path, b"{not json").unwrap();
        let spent = SpentReplies::load(path);
        assert_eq!(spent.claim("r", PHONE, "n", NOW + 60, NOW), Claim::Unreadable);
        assert_eq!(spent.claim_link_reply("r", NOW), Claim::Unreadable);
        assert!(matches!(
            checked(&sealed(text_reply("u-1"), &phone_signer()), &spent),
            Err(Rejection::Unavailable(_))
        ));
        // The file of an older hostd (`{key: until}`) still reads.
        let old = dir.path().join("old.json");
        std::fs::write(&old, serde_json::to_vec(&json!({"id:r": NOW + 60})).unwrap()).unwrap();
        assert_eq!(
            SpentReplies::load(old).claim("r", PHONE, "n", NOW + 60, NOW),
            Claim::Seen { in_progress: false }
        );
    }

    #[test]
    fn a_reply_that_came_over_a_link_is_not_applied_again_from_the_mailbox() {
        // The phone's link failed mid-send and it posted the same reply to the mailbox.
        let spent = SpentReplies::memory();
        assert_eq!(spent.claim_link_reply("r-link", NOW), Claim::Fresh);
        spent.settle("r-link", None);
        let item = sealed(text_reply("r-link"), &phone_signer());
        assert_eq!(checked(&item, &spent), Err(Rejection::Repeat(None)));
        // The other way round: the mailbox applied it, then the link copy arrives.
        let spent = SpentReplies::memory();
        assert!(checked(&sealed(text_reply("r-box"), &phone_signer()), &spent).is_ok());
        spent.settle("r-box", None);
        assert_eq!(spent.claim_link_reply("r-box", NOW), Claim::Settled("applied".into()));
        // And a link copy twice; a released one passes again.
        assert_eq!(spent.claim_link_reply("r-twice", NOW), Claim::Fresh);
        assert_eq!(spent.claim_link_reply("r-twice", NOW + 1), Claim::Seen { in_progress: true });
        spent.release_link_reply("r-twice");
        assert_eq!(spent.claim_link_reply("r-twice", NOW + 2), Claim::Fresh);
    }

    struct Recorder(Mutex<Vec<String>>, Mutex<Vec<Result<(), Rejection>>>);

    impl Recorder {
        fn new(results: Vec<Result<(), Rejection>>) -> Arc<Self> {
            Arc::new(Self(Mutex::default(), Mutex::new(results)))
        }
    }

    impl Applier for Recorder {
        fn apply<'a>(&'a self, reply: &'a Reply) -> BoxFuture<'a, Result<(), Rejection>> {
            self.0.lock().unwrap().push(reply.id.clone());
            let mut results = self.1.lock().unwrap();
            let result = if results.len() > 1 { results.remove(0) } else { results[0].clone() };
            Box::pin(async move { result })
        }
    }

    fn mailbox(applier: Arc<Recorder>) -> Mailbox {
        Mailbox {
            mac: MAC.into(),
            trust: watch::channel(Some(trust())).1,
            identity: watch::channel(Some(mac_identity())).1,
            spent: Arc::new(SpentReplies::memory()),
            cursor: Arc::new(MailboxCursor::memory()),
            order: MailboxOrder::default(),
            applier,
            key_wait: std::time::Duration::from_secs(2),
        }
    }

    /// The fields an ack's signature covers (ECDSA signatures differ each time).
    fn verified(results: &[MailboxResult]) -> Vec<(String, bool, Option<String>)> {
        results
            .iter()
            .map(|r| {
                let message = ack_message(MAC, &r.id, r.applied, r.reason.as_deref());
                assert!(
                    crate::pairing::verify(mac_identity().public_key(), &message, r.sig.as_deref().unwrap()),
                    "{r:?}"
                );
                (r.id.clone(), r.applied, r.reason.clone())
            })
            .collect()
    }

    #[tokio::test]
    async fn the_mailbox_acks_every_settled_item_signed_and_applies_only_checked_ones() {
        let recorder = Recorder::new(vec![Ok(())]);
        let mailbox = mailbox(recorder.clone());
        let good = sealed(text_reply("m-1"), &phone_signer());
        let forged = sealed(text_reply("m-2"), &MacIdentity::generate().unwrap());
        let handled = mailbox.handle(vec![good.clone(), forged, good], NOW).await;
        assert!(handled.later.is_empty());
        assert_eq!(
            verified(&handled.results),
            vec![
                ("m-1".into(), true, None),
                ("m-2".into(), false, Some("bad_signature".into())),
                // The repeat answers the first outcome again.
                ("m-1".into(), true, None),
            ]
        );
        assert_eq!(*recorder.0.lock().unwrap(), vec!["m-1".to_owned()]);
        // A target that no longer waits: settled, and its repeat says so too.
        let stale = super::Mailbox { applier: Recorder::new(vec![Err(Rejection::NotPending)]), ..mailbox };
        let item = sealed(text_reply("m-3"), &phone_signer());
        let handled = stale.handle(vec![item.clone(), item], NOW).await;
        assert_eq!(
            verified(&handled.results),
            vec![
                ("m-3".into(), false, Some("not_pending".into())),
                ("m-3".into(), false, Some("not_pending".into()))
            ]
        );
    }

    #[tokio::test]
    async fn a_reply_that_cannot_be_applied_yet_is_kept_and_applied_later() {
        let recorder = Recorder::new(vec![Err(Rejection::Unavailable("acpmux is down".into())), Ok(())]);
        let mailbox = mailbox(recorder.clone());
        let item = sealed(text_reply("m-5"), &phone_signer());
        let handled = mailbox.handle(vec![item.clone()], NOW).await;
        assert_eq!((handled.results.len(), handled.later.clone()), (0, vec![item.clone()]));
        // Not spent: the next try applies it.
        let handled = mailbox.handle(vec![item], NOW).await;
        assert_eq!(verified(&handled.results), vec![("m-5".into(), true, None)]);
    }

    #[tokio::test]
    async fn a_hostd_that_just_started_waits_for_the_apps_keys() {
        let recorder = Recorder::new(vec![Ok(())]);
        let (identity_tx, identity) = watch::channel(None);
        let mailbox = Mailbox { identity, ..mailbox(recorder.clone()) };
        let item = sealed(text_reply("m-6"), &phone_signer());
        // The key arrives while the item waits: it is applied, not refused "unsealed".
        let handled = {
            let handle = mailbox.handle(vec![item.clone()], NOW);
            let send = async {
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                identity_tx.send(Some(mac_identity())).unwrap();
            };
            tokio::join!(handle, send).0
        };
        assert_eq!(verified(&handled.results), vec![("m-6".into(), true, None)]);
        // No key at all within the wait: kept for later, not acknowledged.
        let (_none_tx, none) = watch::channel(None);
        let blind = Mailbox {
            identity: none,
            spent: Arc::new(SpentReplies::memory()),
            order: MailboxOrder::default(),
            key_wait: std::time::Duration::from_millis(100),
            ..mailbox
        };
        let handled = blind.handle(vec![sealed(text_reply("m-7"), &phone_signer())], NOW).await;
        assert_eq!((handled.results.len(), handled.later.len()), (0, 1));
    }

    // Store and forward (`mailbox-send-v1`): `send`, `compose`, `seq` and the cursor.

    /// A `send` item with `seq`, as a store-and-forward hub delivers it.
    fn send_reply(id: &str) -> Value {
        json!({"v": 1, "id": id, "mac": MAC, "phone": PHONE, "kind": "send",
               "target": {"sessionId": "s1"}, "action": {"type": "text", "text": "run the tests"},
               "nonce": format!("nonce{id}0123456789abcdef").replace('-', ""),
               "issuedAt": NOW - 10, "expiresAt": NOW + 3_600})
    }

    fn queued(id: &str, seq: u64) -> MailboxItem {
        MailboxItem { seq: Some(seq), ..sealed(send_reply(id), &phone_signer()) }
    }

    fn applied_ids(recorder: &Recorder) -> Vec<String> {
        recorder.0.lock().unwrap().clone()
    }

    #[test]
    fn send_and_compose_live_a_day_and_every_other_kind_ten_minutes() {
        assert_eq!((max_lifetime("send"), max_lifetime("compose")), (86_400, 86_400));
        assert_eq!(
            (max_lifetime("completed"), max_lifetime("permission"), max_lifetime("x")),
            (600, 600, 600)
        );
        let spent = SpentReplies::memory();
        let mut day = send_reply("life-1");
        day["issuedAt"] = json!(NOW);
        day["expiresAt"] = json!(NOW + MAX_SEND_LIFETIME);
        assert!(checked(&sealed(day, &phone_signer()), &spent).is_ok());
        let mut longer = send_reply("life-2");
        longer["issuedAt"] = json!(NOW);
        longer["expiresAt"] = json!(NOW + MAX_SEND_LIFETIME + 1);
        assert_eq!(checked(&sealed(longer, &phone_signer()), &spent), Err(Rejection::Expired));
        // A phone clock a little ahead, as for a reply.
        let mut ahead = send_reply("life-3");
        ahead["issuedAt"] = json!(NOW + CLOCK_SKEW);
        ahead["expiresAt"] = json!(NOW + CLOCK_SKEW + MAX_SEND_LIFETIME);
        assert!(checked(&sealed(ahead, &phone_signer()), &spent).is_ok());
        // An old kind keeps 600 s, even sent to a Mac that takes a day for a send.
        let mut old = text_reply("life-4");
        old["issuedAt"] = json!(NOW);
        old["expiresAt"] = json!(NOW + MAX_LIFETIME + 1);
        assert_eq!(checked(&sealed(old, &phone_signer()), &spent), Err(Rejection::Expired));
        let mut hour = text_reply("life-5");
        hour["expiresAt"] = json!(NOW + 3_600);
        assert_eq!(checked(&sealed(hour, &phone_signer()), &spent), Err(Rejection::Expired));
    }

    #[test]
    fn send_and_compose_must_name_what_they_need() {
        let spent = SpentReplies::memory();
        let send = |fields: Value| {
            let mut reply =
                send_reply(&format!("f-{}", crate::seal::sha256_hex(fields.to_string().as_bytes())));
            for (key, value) in fields.as_object().unwrap() {
                reply[key] = value.clone();
            }
            checked(&sealed(reply, &phone_signer()), &spent)
        };
        // A send: steer defaults to true; false is kept; a session and text are needed.
        let reply = send(json!({})).unwrap();
        assert_eq!((reply.kind.as_str(), reply.steer, reply.queue), ("send", true, None));
        assert!(!send(json!({"action": {"type": "text", "text": "later", "steer": false}})).unwrap().steer);
        for bad in [
            json!({"target": {}}),
            json!({"action": {"type": "text", "text": "x", "steer": "yes"}}),
            json!({"action": {"type": "text", "text": " "}}),
            json!({"action": {"type": "queue", "op": "remove", "promptId": "q1"}}),
        ] {
            assert!(matches!(send(bad.clone()), Err(Rejection::Refused(_))), "{bad}");
        }
        // A compose: each op with what it needs.
        let compose = |action: Value| send(json!({"kind": "compose", "action": action}));
        let update = compose(
            json!({"type": "queue", "op": "update", "promptId": "q1", "text": "new words", "index": 3}),
        )
        .unwrap();
        assert_eq!(
            update.queue,
            Some(QueueAction {
                op: "update".into(),
                prompt_id: "q1".into(),
                text: Some("new words".into()),
                index: None
            })
        );
        let moved =
            compose(json!({"type": "queue", "op": "move", "promptId": "q1", "index": 0, "text": "x"}))
                .unwrap();
        assert_eq!(
            moved.queue.unwrap(),
            QueueAction { op: "move".into(), prompt_id: "q1".into(), text: None, index: Some(0) }
        );
        assert!(compose(json!({"type": "queue", "op": "remove", "promptId": "q1"})).is_ok());
        assert!(compose(json!({"type": "queue", "op": "send_now", "promptId": "q1"})).is_ok());
        for bad in [
            json!({"type": "queue", "op": "update", "promptId": "q1"}),
            json!({"type": "queue", "op": "move", "promptId": "q1"}),
            json!({"type": "queue", "op": "remove"}),
            json!({"type": "queue", "op": "interrupt", "promptId": "q1"}),
            json!({"type": "queue", "op": "remove", "promptId": ""}),
            json!({"type": "text", "text": "hi"}),
        ] {
            assert!(matches!(compose(bad.clone()), Err(Rejection::Refused(_))), "{bad}");
        }
    }

    #[test]
    fn the_cursor_survives_a_restart_never_moves_back_and_is_private() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("mailbox-cursor.json");
        let cursor = MailboxCursor::load(path.clone());
        assert_eq!(cursor.get(PHONE), Some(0));
        assert!(cursor.advance(PHONE, 4));
        assert!(cursor.advance(PHONE, 2));
        let again = MailboxCursor::load(path.clone());
        assert_eq!((again.get(PHONE), again.get("other")), (Some(4), Some(0)));
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        // An unreadable file reads as nothing and applies nothing.
        std::fs::write(&path, b"{not json").unwrap();
        let broken = MailboxCursor::load(path);
        assert_eq!(broken.get(PHONE), None);
        assert!(!broken.advance(PHONE, 9));
    }

    #[tokio::test]
    async fn a_redelivered_item_is_never_applied_twice_and_answers_its_first_outcome() {
        let recorder = Recorder::new(vec![Ok(())]);
        let mailbox = mailbox(recorder.clone());
        let first = mailbox.handle(vec![queued("q-1", 1)], NOW).await;
        assert_eq!(verified(&first.results), vec![("q-1".into(), true, None)]);
        assert_eq!(mailbox.cursor.get(PHONE), Some(1));
        // The ack was lost: the hub sends it again on the next socket.
        let again = mailbox.handle(vec![queued("q-1", 1)], NOW + 5).await;
        assert_eq!(verified(&again.results), vec![("q-1".into(), true, None)]);
        assert_eq!(applied_ids(&recorder), vec!["q-1".to_owned()]);
        // A refused item repeats its refusal.
        let stale = Mailbox { applier: Recorder::new(vec![Err(Rejection::NotPending)]), ..mailbox };
        stale.handle(vec![queued("q-2", 2)], NOW).await;
        let again = stale.handle(vec![queued("q-2", 2)], NOW).await;
        assert_eq!(verified(&again.results), vec![("q-2".into(), false, Some("not_pending".into()))]);
        assert_eq!(stale.cursor.get(PHONE), Some(2));
    }

    #[tokio::test]
    async fn a_duplicate_in_one_frame_is_applied_once() {
        let recorder = Recorder::new(vec![Ok(())]);
        let mailbox = mailbox(recorder.clone());
        let handled = mailbox.handle(vec![queued("d-1", 1), queued("d-1", 1)], NOW).await;
        assert_eq!(verified(&handled.results), vec![("d-1".into(), true, None), ("d-1".into(), true, None)]);
        assert_eq!(applied_ids(&recorder), vec!["d-1".to_owned()]);
    }

    #[tokio::test]
    async fn a_phones_items_apply_in_seq_order_across_gaps_and_never_behind_the_cursor() {
        let recorder = Recorder::new(vec![Ok(())]);
        let mailbox = mailbox(recorder.clone());
        // Out of order in one frame: applied 1 then 3 (2 expired at the hub: a gap is fine).
        let handled = mailbox.handle(vec![queued("o-3", 3), queued("o-1", 1)], NOW).await;
        assert_eq!(handled.results.len(), 2);
        assert_eq!(applied_ids(&recorder), vec!["o-1".to_owned(), "o-3".to_owned()]);
        assert_eq!(mailbox.cursor.get(PHONE), Some(3));
        // An item under the cursor the Mac never saw: not applied, `replayed`.
        let late = mailbox.handle(vec![queued("o-2", 2)], NOW).await;
        assert_eq!(verified(&late.results), vec![("o-2".into(), false, Some("replayed".into()))]);
        // A gap after it: applied.
        mailbox.handle(vec![queued("o-7", 7)], NOW).await;
        assert_eq!(applied_ids(&recorder), vec!["o-1".to_owned(), "o-3".to_owned(), "o-7".to_owned()]);
        assert_eq!(mailbox.cursor.get(PHONE), Some(7));
    }

    #[tokio::test]
    async fn an_item_that_cannot_settle_holds_its_phones_later_items_only() {
        // Another paired phone, whose items go on.
        let other_phone = MacIdentity::generate().unwrap();
        const OTHER: &str = "b3b4c6d8-1e3f-4a5b-8c7d-9e0f1a2b3c4d";
        let mut both = trust();
        both.devices.push(TrustedDevice {
            id: OTHER.into(),
            identity_key: other_phone.public_key().to_owned(),
            approval_key: String::new(),
            ..Default::default()
        });
        let other_item = |id: &str, seq: u64| {
            let mut reply = send_reply(id);
            reply["phone"] = json!(OTHER);
            MailboxItem { seq: Some(seq), ..sealed(reply, &other_phone) }
        };
        let recorder = Recorder::new(vec![Err(Rejection::Unavailable("acpmux is down".into())), Ok(())]);
        let mailbox = Mailbox { trust: watch::channel(Some(both)).1, ..mailbox(recorder.clone()) };
        let handled =
            mailbox.handle(vec![queued("h-1", 1), queued("h-2", 2), other_item("x-1", 1)], NOW).await;
        // h-1 could not settle: h-2 was not even tried; the other phone's item was applied.
        assert_eq!(verified(&handled.results), vec![("x-1".into(), true, None)]);
        let later: Vec<_> = handled.later.iter().map(|i| i.id.clone()).collect();
        assert_eq!(later, vec!["h-1".to_owned(), "h-2".to_owned()]);
        assert_eq!(applied_ids(&recorder), vec!["h-1".to_owned(), "x-1".to_owned()]);
        assert_eq!(mailbox.cursor.get(PHONE), Some(0));
        // A later frame never overtakes the held item.
        let next = mailbox.handle(vec![queued("h-3", 3)], NOW).await;
        assert_eq!((next.results.len(), next.later.len()), (0, 1));
        // The retry settles h-1, then the rest in order.
        let retry = mailbox.handle(vec![queued("h-2", 2), queued("h-3", 3), queued("h-1", 1)], NOW).await;
        assert_eq!(retry.results.len(), 3);
        assert!(retry.later.is_empty());
        assert_eq!(
            applied_ids(&recorder),
            vec!["h-1", "x-1", "h-1", "h-2", "h-3"].into_iter().map(str::to_owned).collect::<Vec<_>>()
        );
        assert_eq!(mailbox.cursor.get(PHONE), Some(3));
    }

    #[tokio::test]
    async fn an_item_with_no_seq_goes_by_its_id_alone() {
        // An older hub: no `seq`, the cursor neither read nor moved.
        let recorder = Recorder::new(vec![Ok(())]);
        let mailbox = mailbox(recorder.clone());
        mailbox.cursor.advance(PHONE, 50);
        let item = sealed(send_reply("n-1"), &phone_signer());
        let handled = mailbox.handle(vec![item.clone(), item], NOW).await;
        assert_eq!(verified(&handled.results), vec![("n-1".into(), true, None), ("n-1".into(), true, None)]);
        assert_eq!(applied_ids(&recorder), vec!["n-1".to_owned()]);
        assert_eq!(mailbox.cursor.get(PHONE), Some(50));
    }

    #[tokio::test]
    async fn a_crash_between_the_spent_claim_and_the_cursor_never_applies_twice() {
        let dir = tempfile::tempdir().unwrap();
        let spent_path = dir.path().join("mailbox-spent.json");
        let cursor_path = dir.path().join("mailbox-cursor.json");
        let restarted = |recorder: Arc<Recorder>| Mailbox {
            spent: Arc::new(SpentReplies::load(spent_path.clone())),
            cursor: Arc::new(MailboxCursor::load(cursor_path.clone())),
            ..mailbox(recorder)
        };
        // Applied and settled in the spent file, then hostd died before the cursor was written.
        let before = SpentReplies::load(spent_path.clone());
        let reply = verify(&queued("c-1", 1), MAC, &mac_identity(), &trust(), NOW).unwrap();
        claim(&reply, &before, NOW).unwrap();
        before.settle("c-1", None);
        let recorder = Recorder::new(vec![Ok(())]);
        let handled = restarted(recorder.clone()).handle(vec![queued("c-1", 1)], NOW).await;
        assert_eq!(verified(&handled.results), vec![("c-1".into(), true, None)]);
        assert!(applied_ids(&recorder).is_empty());
        // The redelivery moved the cursor on (written before the ack).
        assert_eq!(MailboxCursor::load(cursor_path.clone()).get(PHONE), Some(1));
        // Claimed, then hostd died mid-apply (no outcome): never applied again, `replayed`.
        let reply = verify(&queued("c-2", 2), MAC, &mac_identity(), &trust(), NOW).unwrap();
        claim(&reply, &SpentReplies::load(spent_path.clone()), NOW).unwrap();
        let handled = restarted(recorder.clone()).handle(vec![queued("c-2", 2)], NOW).await;
        assert_eq!(verified(&handled.results), vec![("c-2".into(), false, Some("replayed".into()))]);
        assert!(applied_ids(&recorder).is_empty());
        assert_eq!(MailboxCursor::load(cursor_path).get(PHONE), Some(2));
    }

    #[tokio::test]
    async fn an_unreadable_cursor_applies_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("mailbox-cursor.json");
        std::fs::write(&path, b"[").unwrap();
        let recorder = Recorder::new(vec![Ok(())]);
        let mailbox = Mailbox { cursor: Arc::new(MailboxCursor::load(path)), ..mailbox(recorder.clone()) };
        let handled =
            mailbox.handle(vec![queued("u-1", 1), sealed(text_reply("u-2"), &phone_signer())], NOW).await;
        assert_eq!((handled.results.len(), handled.later.len()), (0, 2));
        assert!(applied_ids(&recorder).is_empty());
    }
}
