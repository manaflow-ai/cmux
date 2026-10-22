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
//!    they expire, so a restart forgets nothing that still counts);
//! 6. `not_pending`: its question or permission still waits, its session or
//!    Chief conversation exists, its terminal notification is still in the
//!    ledger ([`Applier`]).
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
/// The longest text a reply carries, in bytes.
pub const MAX_TEXT_BYTES: usize = 4096;
/// The largest sealed box accepted (base64url characters).
pub const MAX_SEALED: usize = 8192;
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
        }
    }
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
    pub expires_at: u64,
}

/// The signed bytes: the domain, the Mac, the phone and the lowercase hex
/// SHA-256 of the reply's canonical JSON without `sig`.
pub fn signed_message(mac: &str, phone: &str, unsigned: &Value) -> Vec<u8> {
    let mut canonical = String::new();
    crate::chief_answers::canonical_json(unsigned, &mut canonical);
    crate::seal::joined(DOMAIN, &[mac, phone, &crate::seal::sha256_hex(canonical.as_bytes())])
}

/// Replies and nonces already seen, until they expire. Shared by every
/// signaling socket of this hostd, and kept on disk.
#[derive(Debug, Default)]
pub struct SpentReplies {
    path: Option<PathBuf>,
    spent: Mutex<HashMap<String, u64>>,
}

impl SpentReplies {
    pub fn memory() -> Self {
        Self::default()
    }

    pub fn load(path: PathBuf) -> Self {
        let spent = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<HashMap<String, u64>>(&bytes).ok())
            .unwrap_or_default();
        Self { path: Some(path), spent: Mutex::new(spent) }
    }

    /// Spends the reply's id and nonce until `expires`; false when either
    /// was spent already (nothing changes then).
    pub fn spend(&self, id: &str, phone: &str, nonce: &str, expires: u64, now: u64) -> bool {
        let mut spent = self.spent.lock().unwrap_or_else(PoisonError::into_inner);
        spent.retain(|_, until| *until >= now);
        let keys = [format!("id:{id}"), format!("nonce:{phone}:{nonce}")];
        if keys.iter().any(|k| spent.contains_key(k)) {
            return false;
        }
        for key in keys {
            spent.insert(key, expires);
        }
        if let Some(path) = &self.path
            && let Err(error) =
                crate::push_keys::write_private(path, &serde_json::to_vec(&*spent).unwrap_or_default())
        {
            // Memory still holds it: a replay before a restart is refused anyway.
            tracing::warn!(%error, "could not save spent mailbox replies");
        }
        true
    }
}

/// Checks 1 to 5 for one item.
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
    if expires <= now || expires > issued.saturating_add(MAX_LIFETIME) || expires > now + MAX_LIFETIME {
        return Err(Rejection::Expired);
    }
    let reply = parse(&object, item, expires).map_err(Rejection::Refused)?;
    // 5. Never seen.
    let nonce = text(&object, "nonce").unwrap_or_default();
    if !spent.spend(&reply.id, phone, &nonce, expires, now) {
        return Err(Rejection::Replayed);
    }
    Ok(reply)
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
            needs(option_id.is_some(), "an option id")?;
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
    pub spent: SpentReplies,
    pub applier: Arc<dyn Applier>,
}

impl Mailbox {
    /// Checks and applies each item, in order; one result per item.
    pub async fn handle(&self, items: Vec<MailboxItem>, now: u64) -> Vec<MailboxResult> {
        let mut results = Vec::new();
        for item in items.into_iter().take(MAX_ITEMS) {
            let outcome = self.handle_one(&item, now).await;
            if let Err(rejection) = &outcome {
                tracing::info!(id = item.id, reason = ?rejection, "mailbox reply rejected");
            } else {
                tracing::info!(id = item.id, "mailbox reply applied");
            }
            results.push(MailboxResult {
                id: item.id,
                applied: outcome.is_ok(),
                reason: outcome.err().map(|r| r.code().to_owned()),
            });
        }
        results
    }

    async fn handle_one(&self, item: &MailboxItem, now: u64) -> Result<(), Rejection> {
        let identity = self.identity.borrow().clone().ok_or(Rejection::Unsealed)?;
        let trust = self.trust.borrow().clone().ok_or(Rejection::NotPaired)?;
        let reply = check(item, &self.mac, &identity, &trust, &self.spent, now)?;
        self.applier.apply(&reply).await
    }
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
    fn a_signed_sealed_reply_passes_once() {
        let spent = SpentReplies::memory();
        let item = sealed(text_reply("r-1"), &phone_signer());
        assert!(checked(&item, &spent).is_ok());
        assert_eq!(checked(&item, &spent), Err(Rejection::Replayed));
        // A new id with the same nonce is a replay too.
        let mut again = text_reply("r-2");
        again["nonce"] = text_reply("r-1")["nonce"].clone();
        assert_eq!(checked(&sealed(again, &phone_signer()), &spent), Err(Rejection::Replayed));
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
    fn spent_replies_survive_a_restart_until_they_expire() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("mailbox-spent.json");
        assert!(SpentReplies::load(path.clone()).spend("r", PHONE, "n", NOW + 60, NOW));
        let again = SpentReplies::load(path.clone());
        assert!(!again.spend("r", PHONE, "other", NOW + 60, NOW));
        assert!(!again.spend("other", PHONE, "n", NOW + 60, NOW));
        // After its expiry the record is dropped (an expired reply fails check 4 anyway).
        assert!(SpentReplies::load(path).spend("r", PHONE, "n", NOW + 600, NOW + 61));
    }

    struct Recorder(Mutex<Vec<String>>, Result<(), Rejection>);

    impl Applier for Recorder {
        fn apply<'a>(&'a self, reply: &'a Reply) -> BoxFuture<'a, Result<(), Rejection>> {
            self.0.lock().unwrap().push(reply.id.clone());
            let result = self.1.clone();
            Box::pin(async move { result })
        }
    }

    #[tokio::test]
    async fn the_mailbox_acks_every_item_and_applies_only_checked_ones() {
        let recorder = Arc::new(Recorder(Mutex::default(), Ok(())));
        let mailbox = Mailbox {
            mac: MAC.into(),
            trust: watch::channel(Some(trust())).1,
            identity: watch::channel(Some(mac_identity())).1,
            spent: SpentReplies::memory(),
            applier: recorder.clone(),
        };
        let good = sealed(text_reply("m-1"), &phone_signer());
        let forged = sealed(text_reply("m-2"), &MacIdentity::generate().unwrap());
        let results = mailbox.handle(vec![good.clone(), forged, good], NOW).await;
        assert_eq!(
            results,
            vec![
                MailboxResult { id: "m-1".into(), applied: true, reason: None },
                MailboxResult { id: "m-2".into(), applied: false, reason: Some("bad_signature".into()) },
                MailboxResult { id: "m-1".into(), applied: false, reason: Some("replayed".into()) },
            ]
        );
        assert_eq!(*recorder.0.lock().unwrap(), vec!["m-1".to_owned()]);
        // A target that no longer waits.
        let stale = Mailbox {
            applier: Arc::new(Recorder(Mutex::default(), Err(Rejection::NotPending))),
            spent: SpentReplies::memory(),
            ..mailbox
        };
        let results = stale.handle(vec![sealed(text_reply("m-3"), &phone_signer())], NOW).await;
        assert_eq!(results[0].reason.as_deref(), Some("not_pending"));
        // No identity key from the app yet: nothing opens.
        let blind = Mailbox { identity: watch::channel(None).1, spent: SpentReplies::memory(), ..stale };
        let results = blind.handle(vec![sealed(text_reply("m-4"), &phone_signer())], NOW).await;
        assert_eq!(results[0].reason.as_deref(), Some("unsealed"));
    }
}
