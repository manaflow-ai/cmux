//! Store and forward through the relay's mailbox (PROTOCOL.md "Store and forward"): the router,
//! the sealing and signing of one item, and the post/poll state machine of
//! `cmux_mobile_link::mailbox_client`, for the app. Swift only does the HTTP (with the service's
//! access token), reads its clock, and signs with the phone identity key (Secure Enclave).
//!
//! Every call is pure; one [`MailboxTracker`] per item, called from its owner's actor (a mutex
//! keeps it `Sync` for uniffi and is held only for the call). Time is Unix seconds for items and
//! Unix milliseconds for the tracker.
//!
//! The existing Swift reply path (`MailboxReply`, `LiveCoordinator+PushReply`) stays as it is.
//! TODO(P8 Swift): route the chat composer's send and the queue actions through
//! `mailbox_route` / `mailbox_build` / `MailboxTracker` (the link path's client message id is the
//! item id), and list the Mac's `mailbox-send-v1` from its `version` for `mailbox_available`.

use std::sync::{Mutex, MutexGuard, PoisonError};

use cmux_mobile_link::mailbox_client as core;

/// The phone identity key (a Secure Enclave key in the app).
#[uniffi::export(with_foreign)]
pub trait MailboxSigner: Send + Sync {
    /// ECDSA P-256 / SHA-256 over `message`: raw `r || s`, 64 bytes.
    fn sign(&self, message: Vec<u8>) -> Result<Vec<u8>, MailboxSignError>;
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum MailboxSignError {
    #[error("signing failed: {message}")]
    Failed { message: String },
}

struct SignerAdapter<'a>(&'a dyn MailboxSigner);

impl core::Signer for SignerAdapter<'_> {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, String> {
        self.0.sign(message.to_vec()).map_err(|e| e.to_string())
    }
}

/// Why an item could not be made.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum MailboxError {
    /// The Mac proved no box key (an older Mac): only the link reaches it.
    #[error("the Mac proved no box key")]
    NoBoxKey,
    /// The Mac's box key does not check against its pinned identity key.
    #[error("the Mac's box key does not check against its pinned identity key")]
    UntrustedBoxKey,
    #[error("not supported through the mailbox: {message}")]
    Unsupported { message: String },
    /// Text over the limit, or a sealed item over the service's.
    #[error("too long")]
    TooLong,
    /// An Allow without the approval the phone signed.
    #[error("an Allow needs its signed approval")]
    Unsigned,
    #[error("invalid {field}")]
    Invalid { field: String },
    #[error("expired")]
    Expired,
    #[error("signing failed: {message}")]
    Signing { message: String },
    #[error("crypto: {message}")]
    Crypto { message: String },
}

impl From<core::ItemError> for MailboxError {
    fn from(error: core::ItemError) -> Self {
        use core::ItemError as E;
        match error {
            E::NoBoxKey => Self::NoBoxKey,
            E::UntrustedBoxKey => Self::UntrustedBoxKey,
            E::Unsupported(message) => Self::Unsupported { message: message.into() },
            E::TooLong => Self::TooLong,
            E::Unsigned => Self::Unsigned,
            E::Invalid(field) => Self::Invalid { field: field.into() },
            E::Expired => Self::Expired,
            E::Signing(message) => Self::Signing { message },
            other => Self::Crypto { message: other.to_string() },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MailboxPresence {
    Online,
    Offline,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MailboxRoute {
    /// The normal path, over the link.
    Link,
    /// Seal it and post it to the relay's mailbox.
    Mailbox,
    /// Post it to the chat's Cloud inbox ([`mailbox_inbox_post`]): a Cloud machine holds the chat.
    CloudInbox,
    /// Neither: fail as before.
    Fail,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct MailboxRouteInput {
    pub link_up: bool,
    pub presence: MailboxPresence,
    /// [`mailbox_available`] for this item.
    pub mailbox_available: bool,
    /// The chat's Auto record names a Cloud machine (`vm:`) as its holder.
    pub cloud_holder: bool,
}

/// Link, mailbox, Cloud inbox or fail for one send with client message id `id`. The id is the same
/// on every path, and a Cloud inbox send fails if the inbox would mint a new id.
#[uniffi::export]
pub fn mailbox_route_for(id: String, input: MailboxRouteInput) -> MailboxRoute {
    match core::decide(&id, core_input(input)).route {
        core::Route::Link => MailboxRoute::Link,
        core::Route::Mailbox => MailboxRoute::Mailbox,
        core::Route::CloudInbox => MailboxRoute::CloudInbox,
        core::Route::Fail(_) => MailboxRoute::Fail,
    }
}

/// The Cloud inbox request for one send: `[path, json body]`, or none when the chat id, the id or
/// the text can't go there. Posting the same id again is safe.
#[uniffi::export]
pub fn mailbox_inbox_post(chat_id: String, id: String, text: String) -> Option<Vec<String>> {
    core::inbox_post(&chat_id, &id.to_lowercase(), &text).map(|(path, body)| vec![path, body])
}

fn core_input(input: MailboxRouteInput) -> core::RouteInput {
    let presence = match input.presence {
        MailboxPresence::Online => core::Presence::Online,
        MailboxPresence::Offline => core::Presence::Offline,
        MailboxPresence::Unknown => core::Presence::Unknown,
    };
    core::RouteInput {
        link_up: input.link_up,
        presence,
        mailbox_available: input.mailbox_available,
        cloud_holder: input.cloud_holder,
    }
}

/// Link, mailbox or fail for one send. The item's id is the same on both paths.
#[uniffi::export]
pub fn mailbox_route(input: MailboxRouteInput) -> MailboxRoute {
    match core::route(core_input(input)) {
        core::Route::Link => MailboxRoute::Link,
        core::Route::Mailbox => MailboxRoute::Mailbox,
        core::Route::CloudInbox => MailboxRoute::CloudInbox,
        core::Route::Fail(_) => MailboxRoute::Fail,
    }
}

/// Whether the mailbox can carry an item of `kind`: a trusted box key, and for `send` and
/// `compose` the Mac listed `mailbox-send-v1` on its last link.
#[uniffi::export]
pub fn mailbox_available(kind: String, mac_lists_send_v1: bool, has_trusted_box_key: bool) -> bool {
    core::mailbox_available(&kind, mac_lists_send_v1, has_trusted_box_key)
}

/// The longest an item of `kind` lives, in seconds (540, or 86400 for `send` and `compose`).
#[uniffi::export]
pub fn mailbox_lifetime_cap(kind: String) -> u64 {
    core::lifetime_cap(&kind)
}

/// The Mac's box key (X9.63 hex) once it checks against the pinned identity key; the phone asks
/// before it seals each item.
#[uniffi::export]
pub fn mailbox_trusted_box_key(
    mac: String,
    box_key: Option<String>,
    box_signature: Option<String>,
    pinned_identity: Option<String>,
) -> Result<String, MailboxError> {
    core::trusted_box_key(&mac, box_key.as_deref(), box_signature.as_deref(), pinned_identity.as_deref())?;
    box_key.ok_or(MailboxError::NoBoxKey)
}

/// A fresh nonce as the Mac takes it: 32 lowercase hex digits.
#[uniffi::export]
pub fn mailbox_new_nonce() -> Result<String, MailboxError> {
    core::new_nonce().map_err(|e| MailboxError::Crypto { message: e.to_string() })
}

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct MailboxTarget {
    pub session_id: Option<String>,
    pub permission_id: Option<String>,
    pub conversation_id: Option<String>,
    pub tab_id: Option<String>,
    pub notification_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MailboxAction {
    /// Text; `steer` is the chat Send's (the Mac defaults to true).
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
    /// Composer queue actions (`compose`).
    QueueUpdate {
        prompt_id: String,
        text: String,
    },
    QueueRemove {
        prompt_id: String,
    },
    QueueSendNow {
        prompt_id: String,
    },
    QueueMove {
        prompt_id: String,
        index: u32,
    },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MailboxItemSpec {
    /// The composer's client message id for a `send` (the link path's id too).
    pub id: String,
    pub mac: String,
    pub phone: String,
    /// `send`, `compose`, or the notification's kind.
    pub kind: String,
    pub target: MailboxTarget,
    pub action: MailboxAction,
    /// The acpmux `_meta.acpmux` an Allow carries, as JSON.
    pub approval_json: Option<String>,
    pub nonce: Option<String>,
    /// Unix seconds when the person acted; a retry keeps it.
    pub issued_at: u64,
    pub lifetime_secs: Option<u64>,
}

/// A sealed, signed item: keep it and post the same bytes on a retry.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MailboxSealedItem {
    pub id: String,
    pub mac: String,
    pub phone: String,
    pub kind: String,
    pub sealed: String,
    pub issued_at: u64,
    pub expires_at: u64,
}

impl From<core::SealedItem> for MailboxSealedItem {
    fn from(i: core::SealedItem) -> Self {
        Self {
            id: i.id,
            mac: i.mac,
            phone: i.phone,
            kind: i.kind,
            sealed: i.sealed,
            issued_at: i.issued_at,
            expires_at: i.expires_at,
        }
    }
}

impl From<MailboxSealedItem> for core::SealedItem {
    fn from(i: MailboxSealedItem) -> Self {
        Self {
            id: i.id,
            mac: i.mac,
            phone: i.phone,
            kind: i.kind,
            sealed: i.sealed,
            issued_at: i.issued_at,
            expires_at: i.expires_at,
        }
    }
}

/// Builds, signs (with the phone identity key) and seals `spec` to the Mac's box key (checked by
/// [`mailbox_trusted_box_key`]) at `now` (Unix seconds).
#[uniffi::export]
pub fn mailbox_build(
    spec: MailboxItemSpec,
    box_key: String,
    signer: std::sync::Arc<dyn MailboxSigner>,
    now: u64,
) -> Result<MailboxSealedItem, MailboxError> {
    use core::QueueOp as Q;
    let action = match spec.action {
        MailboxAction::Text { text, steer } => core::Action::Text { text, steer },
        MailboxAction::Allow { option_id } => core::Action::Allow { option_id },
        MailboxAction::Deny { option_id } => core::Action::Deny { option_id },
        MailboxAction::QueueUpdate { prompt_id, text } => core::Action::Queue(Q::Update { prompt_id, text }),
        MailboxAction::QueueRemove { prompt_id } => core::Action::Queue(Q::Remove { prompt_id }),
        MailboxAction::QueueSendNow { prompt_id } => core::Action::Queue(Q::SendNow { prompt_id }),
        MailboxAction::QueueMove { prompt_id, index } => core::Action::Queue(Q::Move { prompt_id, index }),
    };
    let approval = match spec.approval_json {
        Some(json) => Some(
            serde_json::from_str(&json).map_err(|_| MailboxError::Invalid { field: "approval".into() })?,
        ),
        None => None,
    };
    let key = core::seal::public_key_hex(&box_key).map_err(|_| MailboxError::UntrustedBoxKey)?;
    let t = spec.target;
    let spec = core::ItemSpec {
        id: spec.id,
        mac: spec.mac,
        phone: spec.phone,
        kind: spec.kind,
        target: core::Target {
            session_id: t.session_id,
            permission_id: t.permission_id,
            conversation_id: t.conversation_id,
            tab_id: t.tab_id,
            notification_id: t.notification_id,
        },
        action,
        approval,
        nonce: spec.nonce,
        issued_at: spec.issued_at,
        lifetime_secs: spec.lifetime_secs,
    };
    Ok(core::build(&spec, &key, &SignerAdapter(signer.as_ref()), now)?.into())
}

/// What the caller does next for one item.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MailboxStep {
    /// `POST path` with `body` (JSON).
    Post { path: String, body: String },
    /// `GET path`.
    Poll { path: String },
    /// Nothing until `until_ms` (Unix ms).
    Wait { until_ms: u64 },
    /// Settled: read `state`.
    Done,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MailboxState {
    Posting,
    Queued,
    Applied,
    Rejected {
        reason: String,
    },
    Expired,
    /// "Not confirmed by <Mac>": the outcome came without the Mac's valid signature.
    NotConfirmed,
    /// The relay is full for this Mac and phone.
    Full,
    Failed {
        code: String,
    },
}

#[derive(uniffi::Object)]
pub struct MailboxTracker {
    inner: Mutex<core::Tracker>,
}

impl MailboxTracker {
    fn inner(&self) -> MutexGuard<'_, core::Tracker> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[uniffi::export]
impl MailboxTracker {
    /// `pinned_identity`: the Mac's pinned identity key (X9.63 hex); `hub_known_old`: an earlier
    /// post learned the hub reports no `seq` (it then holds items only 10 minutes).
    #[uniffi::constructor]
    pub fn new(
        item: MailboxSealedItem,
        pinned_identity: Option<String>,
        hub_known_old: bool,
        now_ms: u64,
    ) -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self {
            inner: Mutex::new(core::Tracker::new(item.into(), pinned_identity, hub_known_old, now_ms)),
        })
    }

    pub fn next(&self, now_ms: u64) -> MailboxStep {
        match self.inner().next(now_ms) {
            core::Step::Send(core::Request::Post { path, body }) => MailboxStep::Post { path, body },
            core::Step::Send(core::Request::Poll { path }) => MailboxStep::Poll { path },
            core::Step::Wait { until_ms } => MailboxStep::Wait { until_ms },
            core::Step::Done => MailboxStep::Done,
        }
    }

    pub fn on_post(&self, status: u16, body: String, now_ms: u64) {
        self.inner().on_post(status, &body, now_ms);
    }

    pub fn on_poll(&self, status: u16, body: String, now_ms: u64) {
        self.inner().on_poll(status, &body, now_ms);
    }

    /// The request got no answer.
    pub fn on_transport_error(&self, now_ms: u64) {
        self.inner().on_transport_error(now_ms);
    }

    /// Post again (the same bytes) after `Full`.
    pub fn retry(&self, now_ms: u64) {
        self.inner().retry(now_ms);
    }

    pub fn state(&self) -> MailboxState {
        match self.inner().state() {
            core::State::Posting => MailboxState::Posting,
            core::State::Queued => MailboxState::Queued,
            core::State::Applied => MailboxState::Applied,
            core::State::Rejected { reason } => MailboxState::Rejected { reason: reason.clone() },
            core::State::Expired => MailboxState::Expired,
            core::State::NotConfirmed => MailboxState::NotConfirmed,
            core::State::Full => MailboxState::Full,
            core::State::Failed { code } => MailboxState::Failed { code: code.clone() },
        }
    }

    pub fn seq(&self) -> Option<u64> {
        self.inner().seq()
    }
    /// The hub reports no `seq`: it holds items 10 minutes only.
    pub fn old_hub(&self) -> bool {
        self.inner().old_hub()
    }
    pub fn delivered(&self) -> bool {
        self.inner().delivered()
    }
    pub fn expires_at_ms(&self) -> u64 {
        self.inner().expires_at_ms()
    }
    /// The hub answered 401: refresh the token, then ask `next` again.
    pub fn auth_refused(&self) -> bool {
        self.inner().auth_refused()
    }
}

#[cfg(test)]
mod tests;
