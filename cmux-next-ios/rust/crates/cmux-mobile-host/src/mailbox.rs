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
//!    `issuedAt` and now;
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
    // 4. Not expired, and never valid for long.
    let issued = object.get("issuedAt").and_then(Value::as_u64).ok_or(Rejection::Expired)?;
    let expires = object.get("expiresAt").and_then(Value::as_u64).ok_or(Rejection::Expired)?;
    if expires <= now
        || expires > issued.saturating_add(MAX_LIFETIME)
        || expires > now + MAX_LIFETIME + CLOCK_SKEW
    {
        return Err(Rejection::Expired);
    }
    let reply = parse(&object, item, expires).map_err(Rejection::Refused)?;
    // 5. Never seen, or its first outcome again.
    match spent.claim(&reply.id, phone, &reply.nonce, expires, now) {
        Claim::Fresh => Ok(reply),
        Claim::Settled(outcome) => Err(Rejection::Repeat((outcome != "applied").then_some(outcome))),
        Claim::Seen { in_progress: true } => {
            Err(Rejection::Unavailable("another copy is being applied".into()))
        }
        Claim::Seen { in_progress: false } => Err(Rejection::Replayed),
        Claim::Unreadable => Err(Rejection::Unavailable("the spent replies cannot be read".into())),
    }
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
            Some(Value::String(s))
                if !s.is_empty() && s.len() <= 128 && s.chars().all(|c| !c.is_control()) =>
            {
                Ok(Some(s.clone()))
            }
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
        _ => return Err("unknown action".into()),
    };
    let option_id = action_object.get("optionId").and_then(Value::as_str).map(str::to_owned);
    let answers = action_object.get("answers").filter(|a| !a.is_null()).cloned();
    let text = action_object.get("text").and_then(Value::as_str).map(str::to_owned);
    let approval = object.get("approval").filter(|a| !a.is_null()).cloned();
    let needs = |ok: bool, what: &str| if ok { Ok(()) } else { Err(format!("{kind} needs {what}")) };
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
        nonce: nonce.to_owned(),
        expires_at: expires,
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

/// Everything one hostd needs to answer mailbox frames.
pub struct Mailbox {
    pub mac: String,
    pub trust: watch::Receiver<Option<DeviceTrust>>,
    pub identity: watch::Receiver<Option<MacIdentity>>,
    /// Shared with the links (`Pairing::spent_replies`).
    pub spent: Arc<SpentReplies>,
    pub applier: Arc<dyn Applier>,
    /// How long an item waits for the app's keys and paired list (`TRUST_WAIT`).
    pub key_wait: std::time::Duration,
}

impl Mailbox {
    /// Checks and applies each item, in order. Settled items get a signed
    /// result; the rest (`unavailable`) are returned to try again.
    pub async fn handle(&self, items: Vec<MailboxItem>, now: u64) -> Handled {
        let mut handled = Handled::default();
        for item in items.into_iter().take(MAX_ITEMS) {
            let outcome = self.handle_one(&item, now).await;
            let (applied, reason) = match &outcome {
                Ok(()) => (true, None),
                Err(Rejection::Unavailable(why)) => {
                    tracing::info!(id = item.id, why, "mailbox reply not settled yet");
                    handled.later.push(item);
                    continue;
                }
                Err(Rejection::Repeat(first)) => {
                    // A copy of a settled reply: nothing is applied again; its first outcome is
                    // answered (signed) so a lost ack never reads as a failure.
                    tracing::info!(id = item.id, first = ?first, "mailbox reply repeated: not applied again");
                    let identity = self.identity.borrow().clone();
                    let (applied, reason) = (first.is_none(), first.clone());
                    let sig = identity
                        .and_then(|i| i.sign(&ack_message(&self.mac, &item.id, applied, reason.as_deref())));
                    handled.results.push(MailboxResult { id: item.id, applied, reason, sig });
                    continue;
                }
                Err(rejection) => (false, Some(rejection.code().to_owned())),
            };
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
        let reply = check(item, &self.mac, &identity, &trust, &self.spent, now)?;
        let outcome = self.applier.apply(&reply).await;
        match &outcome {
            Err(Rejection::Unavailable(_)) => self.spent.release(&reply.id, &reply.phone, &reply.nonce),
            Ok(()) => self.spent.settle(&reply.id, None),
            Err(rejection) => self.spent.settle(&reply.id, Some(rejection.code())),
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
        MailboxItem { id, from, sealed: boxed, at: None }
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
            key_wait: std::time::Duration::from_millis(100),
            ..mailbox
        };
        let handled = blind.handle(vec![sealed(text_reply("m-7"), &phone_signer())], NOW).await;
        assert_eq!((handled.results.len(), handled.later.len()), (0, 1));
    }
}
