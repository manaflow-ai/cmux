//! Build, sign and seal one mailbox item (PROTOCOL.md "Reply mailbox" and "Store and forward").
//!
//! The plaintext is canonical JSON (`{v, id, mac, phone, kind, target, action, approval?, nonce,
//! issuedAt, expiresAt, sig}`); `sig` is the phone identity signature over
//! `cmux-mobile-reply-v1 \0 mac \0 phone \0 sha256(canonical JSON without sig)`; the whole is
//! sealed to the Mac's box key, which the phone checks against the pinned Mac identity key first.
//! The identity key lives in the Secure Enclave, so the signature comes from a [`Signer`].

use p256::PublicKey;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::canon::{NotCanonical, canonical};
use super::seal::{self, SealError};

/// A reply (and any other kind) stays valid this long: under the Mac's 600 s, so a phone clock a
/// little ahead is still accepted.
pub const REPLY_LIFETIME_SECS: u64 = 540;
/// A `send` or `compose` is held up to a day.
pub const LONG_LIFETIME_SECS: u64 = 86_400;
/// The largest sealed item the service takes (base64url characters).
pub const MAX_SEALED: usize = 16_384;
/// At most this many bytes of text.
pub const MAX_TEXT_BYTES: usize = 4096;
/// The most a hub that does not report `seq` holds an item, in seconds.
pub const OLD_HUB_HOLD_SECS: u64 = 600;

/// The phone identity key (a Secure Enclave key on a phone).
pub trait Signer {
    /// ECDSA P-256 / SHA-256 over `message`, raw `r || s` (64 bytes).
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, String>;
}

/// Why an item could not be made.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ItemError {
    /// The Mac proved no box key (an older Mac): only the link reaches it.
    #[error("the Mac proved no box key")]
    NoBoxKey,
    /// The Mac's box key does not check against its pinned identity key.
    #[error("the Mac's box key does not check against its pinned identity key")]
    UntrustedBoxKey,
    /// This kind of item can't go through the mailbox, or its action does not fit its kind.
    #[error("not supported through the mailbox: {0}")]
    Unsupported(&'static str),
    /// Text over the limit, or a sealed item over the service's.
    #[error("too long")]
    TooLong,
    /// An Allow without the approval the phone signed.
    #[error("an Allow needs its signed approval")]
    Unsigned,
    /// A field the service or Mac would refuse.
    #[error("invalid {0}")]
    Invalid(&'static str),
    /// The item's lifetime has run out already.
    #[error("expired")]
    Expired,
    #[error("signing failed: {0}")]
    Signing(String),
    #[error(transparent)]
    Seal(#[from] SealError),
    #[error(transparent)]
    NotCanonical(#[from] NotCanonical),
}

/// What an item names (all optional; `send` and `compose` need `session_id`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Target {
    pub session_id: Option<String>,
    pub permission_id: Option<String>,
    pub conversation_id: Option<String>,
    pub tab_id: Option<String>,
    pub notification_id: Option<String>,
}

/// A composer queue edit (`compose`), applied as `_acpmux/queue_edit` (`queue_remove` for remove).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum QueueOp {
    Update { prompt_id: String, text: String },
    Remove { prompt_id: String },
    SendNow { prompt_id: String },
    Move { prompt_id: String, index: u32 },
}

/// What an item asks for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Action {
    /// Text to a session, Chief or terminal; `steer` is the chat Send's (the Mac defaults true).
    Text {
        text: String,
        steer: Option<bool>,
    },
    Allow {
        option_id: String,
    },
    Deny {
        option_id: Option<String>,
    },
    Queue(QueueOp),
}

/// Everything one item says before it is signed.
#[derive(Debug, Clone, PartialEq)]
pub struct ItemSpec {
    /// The item's id: for a `send`, the composer's client message id (also the link path's id).
    pub id: String,
    pub mac: String,
    pub phone: String,
    /// `send`, `compose`, or the notification's kind (`question`, `permission`, `completed`, ...).
    pub kind: String,
    pub target: Target,
    pub action: Action,
    /// The acpmux `_meta.acpmux` an Allow carries, signed after Face ID.
    pub approval: Option<Value>,
    /// 16 to 128 letters or digits; `None` makes 32 lowercase hex digits.
    pub nonce: Option<String>,
    /// Unix seconds when the person acted (a retry keeps it).
    pub issued_at: u64,
    /// Wanted lifetime in seconds, capped by the kind (`None`: the cap).
    pub lifetime_secs: Option<u64>,
}

/// The longest an item of `kind` lives.
pub fn lifetime_cap(kind: &str) -> u64 {
    if is_long(kind) { LONG_LIFETIME_SECS } else { REPLY_LIFETIME_SECS }
}

/// `send` and `compose`: the kinds held for hours, that need the Mac to list `mailbox-send-v1`.
pub fn is_long(kind: &str) -> bool {
    kind == "send" || kind == "compose"
}

/// Whether the mailbox can carry an item of `kind` at all: the Mac proved a box key, and for
/// `send` and `compose` it listed `mailbox-send-v1` on its last link.
pub fn mailbox_available(kind: &str, mac_lists_send_v1: bool, has_trusted_box_key: bool) -> bool {
    has_trusted_box_key && (!is_long(kind) || mac_lists_send_v1)
}

/// A sealed, signed item, ready to post (and to keep: a retry posts the same bytes).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SealedItem {
    pub id: String,
    pub mac: String,
    pub phone: String,
    pub kind: String,
    pub sealed: String,
    pub issued_at: u64,
    pub expires_at: u64,
}

impl SealedItem {
    /// Seconds left at `now` (Unix seconds); 0 when it ran out.
    pub fn time_left(&self, now: u64) -> u64 {
        self.expires_at.saturating_sub(now)
    }

    /// `hold` for a post at `now`: the time left, 1 to 86400, and at most 600 for a hub known to
    /// ignore it. `None` when no time is left.
    pub fn hold(&self, now: u64, old_hub: bool) -> Option<u64> {
        let left = self.time_left(now);
        if left == 0 {
            return None;
        }
        let cap = if old_hub { OLD_HUB_HOLD_SECS } else { LONG_LIFETIME_SECS };
        Some(left.clamp(1, cap))
    }

    /// The body of `POST /v1/devices/:mac/mailbox`.
    pub fn post_body(&self, now: u64, old_hub: bool) -> Option<String> {
        let hold = self.hold(now, old_hub)?;
        Some(json!({"id": self.id, "from": self.phone, "sealed": self.sealed, "hold": hold}).to_string())
    }
}

/// The Mac's box key, checked against its pinned identity key before an item is sealed to it:
/// a keychain entry another process changed can't redirect items.
pub fn trusted_box_key(
    mac: &str,
    box_key_hex: Option<&str>,
    box_signature_hex: Option<&str>,
    pinned_identity_hex: Option<&str>,
) -> Result<PublicKey, ItemError> {
    let box_key = box_key_hex.ok_or(ItemError::NoBoxKey)?;
    let (Some(signature), Some(pinned)) = (box_signature_hex, pinned_identity_hex) else {
        return Err(ItemError::UntrustedBoxKey);
    };
    let message = seal::box_key_message(&mac.to_lowercase(), box_key);
    if !seal::verify(pinned, &message, signature) {
        return Err(ItemError::UntrustedBoxKey);
    }
    seal::public_key_hex(box_key).map_err(|_| ItemError::UntrustedBoxKey)
}

/// A one-time nonce as the Mac takes it: 32 lowercase hex digits.
pub fn new_nonce() -> Result<String, SealError> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| SealError::Random)?;
    Ok(seal::hex(&bytes))
}

fn check_text(text: &str) -> Result<(), ItemError> {
    if text.len() > MAX_TEXT_BYTES { Err(ItemError::TooLong) } else { Ok(()) }
}

fn action_json(kind: &str, action: &Action) -> Result<Value, ItemError> {
    let long = is_long(kind);
    Ok(match action {
        Action::Text { text, steer } => {
            check_text(text)?;
            if kind == "compose" {
                return Err(ItemError::Unsupported("compose takes a queue action"));
            }
            let mut object = Map::new();
            object.insert("type".into(), "text".into());
            object.insert("text".into(), text.clone().into());
            if let Some(steer) = steer {
                if kind != "send" {
                    return Err(ItemError::Unsupported("steer is for send"));
                }
                object.insert("steer".into(), (*steer).into());
            }
            Value::Object(object)
        }
        Action::Allow { option_id } if !long => json!({"type": "allow", "optionId": option_id}),
        Action::Deny { option_id } if !long => match option_id {
            Some(id) => json!({"type": "deny", "optionId": id}),
            None => json!({"type": "deny"}),
        },
        Action::Allow { .. } | Action::Deny { .. } => return Err(ItemError::Unsupported("send takes text")),
        Action::Queue(op) => {
            if kind != "compose" {
                return Err(ItemError::Unsupported("a queue action is for compose"));
            }
            let (name, prompt, text, index) = match op {
                QueueOp::Update { prompt_id, text } => ("update", prompt_id, Some(text), None),
                QueueOp::Remove { prompt_id } => ("remove", prompt_id, None, None),
                QueueOp::SendNow { prompt_id } => ("send_now", prompt_id, None, None),
                QueueOp::Move { prompt_id, index } => ("move", prompt_id, None, Some(*index)),
            };
            if prompt.is_empty() {
                return Err(ItemError::Invalid("promptId"));
            }
            let mut object = Map::new();
            object.insert("type".into(), "queue".into());
            object.insert("op".into(), name.into());
            object.insert("promptId".into(), prompt.clone().into());
            if let Some(text) = text {
                check_text(text)?;
                object.insert("text".into(), text.clone().into());
            }
            if let Some(index) = index {
                object.insert("index".into(), index.into());
            }
            Value::Object(object)
        }
    })
}

/// Builds, signs and seals `spec` at `now` (Unix seconds).
pub fn build(
    spec: &ItemSpec,
    box_key: &PublicKey,
    signer: &dyn Signer,
    now: u64,
) -> Result<SealedItem, ItemError> {
    let id = uuid::Uuid::parse_str(&spec.id).map_err(|_| ItemError::Invalid("id"))?.hyphenated().to_string();
    if spec.kind.is_empty() {
        return Err(ItemError::Invalid("kind"));
    }
    if is_long(&spec.kind) && spec.target.session_id.is_none() {
        return Err(ItemError::Invalid("sessionId"));
    }
    if matches!(spec.action, Action::Allow { .. }) && spec.approval.is_none() {
        return Err(ItemError::Unsigned);
    }
    let nonce = match &spec.nonce {
        Some(n) if (16..=128).contains(&n.len()) && n.bytes().all(|b| b.is_ascii_alphanumeric()) => n.clone(),
        Some(_) => return Err(ItemError::Invalid("nonce")),
        None => new_nonce()?,
    };
    let cap = lifetime_cap(&spec.kind);
    let expires_at = spec.issued_at + spec.lifetime_secs.unwrap_or(cap).clamp(1, cap);
    if expires_at <= now {
        return Err(ItemError::Expired);
    }
    let mut target = Map::new();
    for (key, value) in [
        ("sessionId", &spec.target.session_id),
        ("permissionId", &spec.target.permission_id),
        ("conversationId", &spec.target.conversation_id),
        ("tabId", &spec.target.tab_id),
        ("notificationId", &spec.target.notification_id),
    ] {
        if let Some(value) = value {
            target.insert(key.into(), value.clone().into());
        }
    }
    let mut object = Map::new();
    object.insert("v".into(), 1.into());
    object.insert("id".into(), id.clone().into());
    object.insert("mac".into(), spec.mac.clone().into());
    object.insert("phone".into(), spec.phone.clone().into());
    object.insert("kind".into(), spec.kind.clone().into());
    object.insert("target".into(), Value::Object(target));
    object.insert("action".into(), action_json(&spec.kind, &spec.action)?);
    object.insert("nonce".into(), nonce.into());
    object.insert("issuedAt".into(), spec.issued_at.into());
    object.insert("expiresAt".into(), expires_at.into());
    if let Some(approval) = &spec.approval {
        object.insert("approval".into(), approval.clone());
    }
    let unsigned = canonical(&Value::Object(object.clone()))?;
    let signature =
        signer.sign(&seal::signed_message(&spec.mac, &spec.phone, &unsigned)).map_err(ItemError::Signing)?;
    if signature.len() != 64 {
        return Err(ItemError::Signing("not a raw r || s signature".into()));
    }
    object.insert("sig".into(), seal::hex(&signature).into());
    let plaintext = canonical(&Value::Object(object))?;
    let sealed =
        seal::seal(box_key, &seal::reply_context(&spec.mac, &spec.phone, &id), plaintext.as_bytes())?;
    if sealed.len() > MAX_SEALED {
        return Err(ItemError::TooLong);
    }
    Ok(SealedItem {
        id,
        mac: spec.mac.clone(),
        phone: spec.phone.clone(),
        kind: spec.kind.clone(),
        sealed,
        issued_at: spec.issued_at,
        expires_at,
    })
}
