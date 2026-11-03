//! Device pairing (cmux-next-ios `verify/phone-approvals.md`, audit B2): a Stack
//! token alone never reaches the Mac's terminals and agents.
//!
//! - Each phone holds two Secure Enclave P-256 keys: an identity key that
//!   signs without a prompt, and an approval key that needs Face ID.
//! - The first channel of every link is `auth` with `{identityKey,
//!   approvalKey, name}`. hostd sends a fresh challenge; the phone signs
//!   [`challenge_message`] with its identity key. A channel the phone opens
//!   after `auth` waits for its outcome (so a link opens its channels at
//!   once); one opened with no `auth` before it is refused with `unpaired`.
//! - A key pair the Mac already approved for this device id passes at once.
//!   Otherwise hostd asks the app (`pair_request`), which asks the user ("Allow
//!   <phone> to connect?"), and waits up to [`APPROVAL_WAIT`] for the app's
//!   next `devices` list to approve or deny it.
//! - `{action: "unpair"}` with a valid signature by an approved key tells the
//!   app to forget that device (the phone's sign-out).
//!
//! - Limits (review M4, a stolen token must not wear the person down with
//!   prompts): one `auth` at a time per link (another is refused `busy`); at
//!   most [`MAX_WAITERS`] channels wait behind it; new keys ask at most
//!   [`KEYS_PER_DEVICE`] times per device id and [`PROMPTS_PER_ACCOUNT`] times
//!   in all per [`PROMPT_WINDOW`]; after the person refuses a key, that device
//!   id asks nothing for [`DENY_COOLDOWN`] whatever key it brings. A request
//!   over a limit is refused `rate_limited`.
//! - hostd asks nothing until the app sent its first `devices` list (a paired
//!   phone right after a hostd restart is never asked again), waiting at most
//!   [`TRUST_WAIT`] for it.
//!
//! The device id is the link's authenticated sender (backend-stamped), never
//! an argument. Unsupervised hostd (tests, `run-host.sh`) runs without
//! pairing, as before.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use cmux_mobile_link::ChannelEvent;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use futures_util::future::BoxFuture;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::watch;

use crate::control::Event;

/// How long a link waits for the user to answer the Mac's pairing prompt.
pub const APPROVAL_WAIT: Duration = Duration::from_secs(120);
/// How long hostd waits for the phone's signature.
const SIGNATURE_WAIT: Duration = Duration::from_secs(30);
const DOMAIN: &str = "cmux-mobile-link-auth-v1";
/// How long a request waits for the app's first `devices` list.
pub const TRUST_WAIT: Duration = Duration::from_secs(10);
/// How many channels may wait behind a link's running `auth`.
pub const MAX_WAITERS: usize = 32;
/// After the person refuses a key, how long that device id asks nothing.
pub const DENY_COOLDOWN: Duration = Duration::from_secs(10 * 60);
/// The window the prompt counts below cover.
pub const PROMPT_WINDOW: Duration = Duration::from_secs(10 * 60);
/// New identity keys one device id may ask about per window.
pub const KEYS_PER_DEVICE: usize = 3;
/// New identity keys all phones together may ask about per window.
pub const PROMPTS_PER_ACCOUNT: usize = 6;
/// How long the registration date lookup may hold a prompt back.
const REGISTRATION_WAIT: Duration = Duration::from_secs(3);

/// Looks up when a phone device id first registered with the service
/// (epoch milliseconds), for the pairing prompt. `None`: unknown.
pub type RegistrationLookup = Arc<dyn Fn(String) -> BoxFuture<'static, Option<i64>> + Send + Sync>;

/// Epoch milliseconds of an RFC 3339 UTC time as the service writes it
/// (`2026-10-14T07:12:09.681Z`, fraction optional, `Z` or `+00:00`).
pub fn epoch_millis(text: &str) -> Option<i64> {
    let text = text.strip_suffix('Z').or_else(|| text.strip_suffix("+00:00"))?;
    let (date, time) = text.split_once('T')?;
    let mut date = date.split('-').map(|p| p.parse::<i64>().ok());
    let (year, month, day) = (date.next()??, date.next()??, date.next()??);
    let (clock, fraction) = time.split_once('.').unwrap_or((time, ""));
    let mut clock = clock.split(':').map(|p| p.parse::<i64>().ok());
    let (hour, minute, second) = (clock.next()??, clock.next()??, clock.next()??);
    if date.next().is_some()
        || clock.next().is_some()
        || !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
    {
        return None;
    }
    let millis = if fraction.is_empty() {
        0
    } else {
        if !fraction.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        format!("{fraction:0<3}")[..3].parse::<i64>().ok()?
    };
    // Days from 1970-01-01 (Howard Hinnant's days_from_civil).
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(((days * 24 + hour) * 60 + minute) * 60_000 + second * 1000 + millis)
}

/// One device the Mac approved.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct TrustedDevice {
    pub id: String,
    /// The 65-byte X9.63 identity key, lowercase hex.
    pub identity_key: String,
    /// The approval key, lowercase hex (empty: none).
    #[serde(default)]
    pub approval_key: String,
}

/// What the app approved and refused, as it last said.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct DeviceTrust {
    pub devices: Vec<TrustedDevice>,
    /// Identity keys the user refused for a device id: refused at once, never asked again.
    #[serde(default)]
    pub denied: Vec<DeniedDevice>,
}

/// One request the user refused: that device id with that identity key.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct DeniedDevice {
    pub id: String,
    pub identity_key: String,
}

/// Where a decision about this request stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Standing {
    Trusted,
    Denied,
    Unknown,
}

impl DeviceTrust {
    pub fn standing(&self, id: &str, identity_key: &str, approval_key: &str) -> Standing {
        if self
            .devices
            .iter()
            .any(|d| d.id == id && d.identity_key == identity_key && d.approval_key == approval_key)
        {
            Standing::Trusted
        } else if self.denied.iter().any(|d| d.id == id && d.identity_key == identity_key) {
            Standing::Denied
        } else {
            Standing::Unknown
        }
    }

    fn knows_identity(&self, id: &str, identity_key: &str) -> bool {
        self.devices.iter().any(|d| d.id == id && d.identity_key == identity_key)
    }
}

/// Pairing for a supervised hostd.
#[derive(Clone)]
pub struct Pairing {
    /// This Mac's device id (bound into every challenge).
    pub mac_device_id: String,
    /// The app's latest `devices` line (`None` until it sends one).
    pub trust: watch::Receiver<Option<DeviceTrust>>,
    /// Where events for the app go (stdout when supervised).
    pub emit: Arc<dyn Fn(Event) + Send + Sync>,
    /// The prompt limits, shared by every link of this hostd.
    pub limiter: Arc<Mutex<PromptLimiter>>,
    /// The phone's registration date for the prompt (`None`: not looked up).
    pub registration: Option<RegistrationLookup>,
    /// Chief answer approvals already spent (`chief_answers.rs`), for every link.
    pub spent_answers: Arc<crate::chief_answers::SpentNonces>,
    /// This Mac's long-lived identity key (the app keeps it in the Keychain and
    /// sends it over stdin): proves the Mac to a phone that pinned it.
    pub identity: watch::Receiver<Option<MacIdentity>>,
    /// Paired phones' push keys (`push_keys.rs`), sent with `auth`.
    pub push_keys: Arc<crate::push_keys::PushKeys>,
    /// Notification replies already applied, over a link or from the mailbox
    /// (`mailbox.rs`): a reply that came both ways is applied once.
    pub spent_replies: Arc<crate::mailbox::SpentReplies>,
}

impl Pairing {
    pub fn new(
        mac_device_id: String,
        trust: watch::Receiver<Option<DeviceTrust>>,
        emit: Arc<dyn Fn(Event) + Send + Sync>,
    ) -> Self {
        Self {
            mac_device_id,
            trust,
            emit,
            limiter: Arc::default(),
            registration: None,
            spent_answers: Arc::default(),
            identity: watch::channel(None).1,
            push_keys: Arc::new(crate::push_keys::PushKeys::memory()),
            spent_replies: Arc::new(crate::mailbox::SpentReplies::memory()),
        }
    }

    /// With the store of applied notification replies.
    pub fn with_spent_replies(mut self, spent: Arc<crate::mailbox::SpentReplies>) -> Self {
        self.spent_replies = spent;
        self
    }

    /// With a store for the phones' push keys.
    pub fn with_push_keys(mut self, push_keys: Arc<crate::push_keys::PushKeys>) -> Self {
        self.push_keys = push_keys;
        self
    }
}

/// What one device id asked recently.
#[derive(Debug, Default)]
struct DeviceAsks {
    /// New identity keys asked about, with when (pruned to [`PROMPT_WINDOW`]).
    recent: Vec<(String, Instant)>,
    /// Every identity key this hostd asked about for the device.
    asked: HashSet<String>,
    /// Refusals already counted.
    denials: HashSet<String>,
    denied_at: Option<Instant>,
}

/// Rate limits for pairing prompts (review M4).
#[derive(Debug, Default)]
pub struct PromptLimiter {
    devices: HashMap<String, DeviceAsks>,
    /// Every new-key prompt of this hostd in the window.
    recent: VecDeque<Instant>,
}

impl PromptLimiter {
    /// Whether hostd may ask about `identity_key` for `id` now; records the
    /// ask when it may. `Err` carries how long until it may.
    pub fn admit(
        &mut self,
        id: &str,
        identity_key: &str,
        trust: &DeviceTrust,
        now: Instant,
    ) -> Result<(), Duration> {
        let asks = self.devices.entry(id.to_owned()).or_default();
        // A refusal of a key this hostd asked about (seen even when that
        // request's channel was gone before the person answered).
        for denied in trust.denied.iter().filter(|d| d.id == id) {
            if asks.asked.contains(&denied.identity_key) && asks.denials.insert(denied.identity_key.clone()) {
                asks.denied_at = Some(now);
            }
        }
        if let Some(at) = asks.denied_at {
            let until = at + DENY_COOLDOWN;
            if now < until {
                return Err(until - now);
            }
        }
        asks.recent.retain(|(_, at)| now.duration_since(*at) < PROMPT_WINDOW);
        if asks.recent.iter().any(|(key, _)| key == identity_key) {
            // The same key again (say after nobody answered): no new key.
            return Ok(());
        }
        if asks.recent.len() >= KEYS_PER_DEVICE {
            return Err(PROMPT_WINDOW.saturating_sub(now.duration_since(asks.recent[0].1)));
        }
        while self.recent.front().is_some_and(|at| now.duration_since(*at) >= PROMPT_WINDOW) {
            self.recent.pop_front();
        }
        if self.recent.len() >= PROMPTS_PER_ACCOUNT {
            let oldest = *self.recent.front().expect("non-empty");
            return Err(PROMPT_WINDOW.saturating_sub(now.duration_since(oldest)));
        }
        self.recent.push_back(now);
        asks.recent.push((identity_key.to_owned(), now));
        asks.asked.insert(identity_key.to_owned());
        Ok(())
    }

    /// The person refused `identity_key` for `id`.
    pub fn denied(&mut self, id: &str, identity_key: &str, now: Instant) {
        let asks = self.devices.entry(id.to_owned()).or_default();
        if asks.asked.contains(identity_key) && asks.denials.insert(identity_key.to_owned()) {
            asks.denied_at = Some(now);
        }
    }
}

fn wait_text(wait: Duration) -> String {
    let minutes = wait.as_secs().div_ceil(60).max(1);
    if minutes == 1 { "1 minute".into() } else { format!("{minutes} minutes") }
}

impl std::fmt::Debug for Pairing {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Pairing").field("mac_device_id", &self.mac_device_id).finish_non_exhaustive()
    }
}

/// Where a link's `auth` stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AuthState {
    /// No `auth` channel is running, and none passed.
    Idle,
    /// This many `auth` channels are running and none passed yet.
    Running(usize),
    /// The phone proved keys the Mac approved (for the life of the link).
    Paired,
}

/// Whether this link's phone proved an approved key.
#[derive(Debug)]
pub struct LinkAuth {
    state: watch::Sender<AuthState>,
    waiters: std::sync::atomic::AtomicUsize,
}

impl Default for LinkAuth {
    fn default() -> Self {
        Self { state: watch::channel(AuthState::Idle).0, waiters: std::sync::atomic::AtomicUsize::new(0) }
    }
}

/// Whether a channel may be served.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gate {
    Paired,
    /// Not paired: refused `unpaired`.
    Unpaired,
    /// Too many channels already wait behind `auth`: refused `busy`.
    Busy,
}

impl LinkAuth {
    pub fn is_authenticated(&self) -> bool {
        *self.state.borrow() == AuthState::Paired
    }

    /// An `auth` channel opened (called by the link's accept loop, in open
    /// order): channels opened after it wait for the outcome ([`LinkAuth::paired`]).
    /// Every `begin` is matched by one [`LinkAuth::end`].
    pub fn begin(&self) {
        self.state.send_modify(|state| {
            *state = match *state {
                AuthState::Paired => AuthState::Paired,
                AuthState::Idle => AuthState::Running(1),
                AuthState::Running(n) => AuthState::Running(n + 1),
            }
        });
    }

    /// [`LinkAuth::begin`] unless an `auth` is already running on the link:
    /// a link has one `auth` at a time (the extra one is refused `busy`).
    pub fn try_begin(&self) -> bool {
        let mut started = false;
        self.state.send_if_modified(|state| match *state {
            AuthState::Running(_) => false,
            AuthState::Paired => {
                started = true;
                false
            }
            AuthState::Idle => {
                started = true;
                *state = AuthState::Running(1);
                true
            }
        });
        started
    }

    /// An `auth` channel finished; `paired` when it proved approved keys.
    /// Waiters are refused only when no other `auth` on the link is still running.
    pub fn end(&self, paired: bool) {
        self.state.send_modify(|state| {
            *state = match (*state, paired) {
                (AuthState::Paired, _) | (_, true) => AuthState::Paired,
                (AuthState::Running(n), false) if n > 1 => AuthState::Running(n - 1),
                _ => AuthState::Idle,
            }
        });
    }

    /// Whether the link is paired, waiting while an `auth` opened before this
    /// channel is still running (at most the signature and approval waits).
    /// At most [`MAX_WAITERS`] channels wait; one more is [`Gate::Busy`].
    pub async fn gate(&self) -> Gate {
        use std::sync::atomic::Ordering;
        match *self.state.borrow() {
            AuthState::Paired => return Gate::Paired,
            AuthState::Idle => return Gate::Unpaired,
            AuthState::Running(_) => {}
        }
        if self.waiters.fetch_add(1, Ordering::SeqCst) >= MAX_WAITERS {
            self.waiters.fetch_sub(1, Ordering::SeqCst);
            return Gate::Busy;
        }
        let paired = self.paired().await;
        self.waiters.fetch_sub(1, Ordering::SeqCst);
        if paired { Gate::Paired } else { Gate::Unpaired }
    }

    /// Whether the link is paired, waiting while an `auth` is running.
    pub async fn paired(&self) -> bool {
        let mut state = self.state.subscribe();
        let wait = tokio::time::timeout(
            SIGNATURE_WAIT + TRUST_WAIT + APPROVAL_WAIT + Duration::from_secs(5),
            async {
                loop {
                    match *state.borrow_and_update() {
                        AuthState::Paired => return true,
                        AuthState::Idle => return false,
                        AuthState::Running(_) => {}
                    }
                    if state.changed().await.is_err() {
                        return false;
                    }
                }
            },
        );
        wait.await.unwrap_or(false)
    }
}

/// The bytes the phone's identity key signs.
pub fn challenge_message(
    mac: &str,
    phone: &str,
    nonce: &str,
    identity_key: &str,
    approval_key: &str,
    action: &str,
) -> Vec<u8> {
    let mut out = DOMAIN.as_bytes().to_vec();
    for part in [mac, phone, nonce, identity_key, approval_key, action] {
        out.push(0);
        out.extend_from_slice(part.as_bytes());
    }
    out
}

/// A refusal: close code and reason.
pub type Refused = (&'static str, String);

/// The domain of the Mac's identity proof.
const MAC_DOMAIN: &str = "cmux-mobile-mac-identity-v1";

/// The bytes the Mac's identity key signs for a phone: this Mac's device id,
/// the phone, the phone's own nonce (`macNonce`, so a recorded proof cannot be
/// replayed) and this `auth`'s challenge.
pub fn mac_proof_message(mac: &str, phone: &str, phone_nonce: &str, challenge: &str) -> Vec<u8> {
    let mut out = MAC_DOMAIN.as_bytes().to_vec();
    for part in [mac, phone, phone_nonce, challenge] {
        out.push(0);
        out.extend_from_slice(part.as_bytes());
    }
    out
}

/// This Mac's long-lived P-256 identity key (the app keeps it in the
/// Keychain). A phone pins its public key per Mac device id the first time
/// it pairs, and refuses a Mac that cannot prove it later (PROTOCOL.md
/// "Mac identity").
#[derive(Clone)]
pub struct MacIdentity {
    pair: Arc<ring::signature::EcdsaKeyPair>,
    public: String,
    /// The box key derived from the identity scalar (`seal::box_key`):
    /// mailbox replies are sealed to it.
    boxed: Arc<p256::SecretKey>,
    box_public: String,
}

impl std::fmt::Debug for MacIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MacIdentity").field("public", &self.public).finish_non_exhaustive()
    }
}

impl MacIdentity {
    /// From the raw 32-byte private scalar and the X9.63 public point, as hex.
    pub fn from_raw(private_hex: &str, public_hex: &str) -> Option<Self> {
        if !is_point(public_hex) {
            return None;
        }
        let (private, public) = (unhex(private_hex)?, unhex(public_hex)?);
        let pair = ring::signature::EcdsaKeyPair::from_private_key_and_public_key(
            &ring::signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            &private,
            &public,
            &ring::rand::SystemRandom::new(),
        )
        .ok()?;
        let boxed = crate::seal::box_key(&private)?;
        let box_public = crate::seal::point_hex(&boxed.public_key());
        Some(Self { pair: Arc::new(pair), public: public_hex.to_owned(), boxed: Arc::new(boxed), box_public })
    }

    /// A fresh key (tests, and a hostd that runs without the app).
    pub fn generate() -> Option<Self> {
        let secret = crate::seal::random_secret().ok()?;
        Self::from_raw(&crate::seal::hex(&secret.to_bytes()), &crate::seal::point_hex(&secret.public_key()))
    }

    /// The X9.63 public point as lowercase hex.
    pub fn public_key(&self) -> &str {
        &self.public
    }

    /// The box key's X9.63 point as lowercase hex.
    pub fn box_public_key(&self) -> &str {
        &self.box_public
    }

    /// The box key (opens mailbox replies).
    pub fn box_secret(&self) -> &p256::SecretKey {
        &self.boxed
    }

    /// Raw `r || s` over `message`, as hex.
    pub fn sign(&self, message: &[u8]) -> Option<String> {
        let signature = self.pair.sign(&ring::rand::SystemRandom::new(), message).ok()?;
        Some(signature.as_ref().iter().map(|b| format!("{b:02x}")).collect())
    }
}

impl Pairing {
    /// With the app's identity key line (`mac_identity`).
    pub fn with_identity(mut self, identity: watch::Receiver<Option<MacIdentity>>) -> Self {
        self.identity = identity;
        self
    }
}

fn is_point(hex: &str) -> bool {
    hex.len() == 130
        && hex.starts_with("04")
        && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok()).collect()
}

/// A pairing code's pre-approval as the Mac mints it: 16 to 64 base64url characters.
fn is_pair_token(token: &str) -> bool {
    (16..=64).contains(&token.len())
        && token.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn new_nonce() -> Result<String, Refused> {
    use ring::rand::SecureRandom;
    let mut bytes = [0u8; 32];
    ring::rand::SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| ("unavailable", "no randomness".to_owned()))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// Verifies `signature` (raw `r || s`, hex) by the X9.63 key `key_hex`.
pub fn verify(key_hex: &str, message: &[u8], signature: &str) -> bool {
    let (Some(key), Some(signature)) = (unhex(key_hex), unhex(signature)) else { return false };
    signature.len() == 64
        && ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, &key)
            .verify(message, &signature)
            .is_ok()
}

/// The `auth` service: prove the identity key, then pass if the Mac approved
/// this device's keys, else ask the app and wait for the user.
///
/// The caller marks the channel's open with [`LinkAuth::begin`] first.
pub async fn serve(
    pairing: Option<&Pairing>,
    phone: &str,
    link: &LinkAuth,
    args: &Value,
    sender: &ChannelSender,
    receiver: &mut ChannelReceiver,
) -> Result<(), Refused> {
    // The accept loop counted this channel when it opened (`begin`).
    let result = authenticate(pairing, phone, args, sender, receiver).await;
    link.end(result.is_ok() && action_is_pair(args));
    result
}

fn action_is_pair(args: &Value) -> bool {
    matches!(args.get("action").and_then(Value::as_str), None | Some("" | "pair"))
}

async fn authenticate(
    pairing: Option<&Pairing>,
    phone: &str,
    args: &Value,
    sender: &ChannelSender,
    receiver: &mut ChannelReceiver,
) -> Result<(), Refused> {
    let text = |key: &str| args.get(key).and_then(Value::as_str).unwrap_or_default();
    let identity_key = text("identityKey");
    let approval_key = text("approvalKey");
    let action = match text("action") {
        "" | "pair" => "pair",
        "unpair" => "unpair",
        _ => return Err(("bad_request", "action is pair or unpair".into())),
    };
    if !is_point(identity_key) || !(approval_key.is_empty() || is_point(approval_key)) {
        return Err(("bad_request", "keys must be 65-byte uncompressed P-256 points as hex".into()));
    }
    let name: String = text("name").chars().filter(|c| !c.is_control()).take(64).collect();
    let Some(pairing) = pairing else {
        // Unsupervised: no app to approve; every link is served as before.
        send(sender, json!({"ok": true})).await;
        return Ok(());
    };
    // A push key that does not check out costs only the sealed pushes, never
    // the pairing (PR B review 7): that phone gets the plain content as before.
    let push_key =
        push_key_arg(args, &pairing.mac_device_id, phone, identity_key).unwrap_or_else(|(_, why)| {
            tracing::warn!(phone, why, "ignoring a push key");
            None
        });
    let nonce = new_nonce()?;
    let mut challenge = json!({"challenge": nonce, "mac": pairing.mac_device_id});
    // A phone that pins Macs sends its own nonce: the Mac signs it with its
    // identity key, so a host registered with a stolen token cannot pass as it.
    let phone_nonce = text("macNonce");
    if !phone_nonce.is_empty() {
        if !(16..=128).contains(&phone_nonce.len()) || !phone_nonce.bytes().all(|b| b.is_ascii_alphanumeric())
        {
            return Err(("bad_request", "macNonce is 16 to 128 letters or digits".into()));
        }
        let identity = pairing.identity.borrow().clone();
        if let Some(identity) = identity {
            let proof = mac_proof_message(&pairing.mac_device_id, phone, phone_nonce, &nonce);
            challenge["macKey"] = json!(identity.public_key());
            challenge["macSignature"] = json!(identity.sign(&proof));
            // The box key replies are sealed to, vouched for by the identity key
            // the phone pins (PROTOCOL.md "Keys at pairing").
            let statement = crate::seal::box_key_message(&pairing.mac_device_id, identity.box_public_key());
            challenge["macBoxKey"] = json!(identity.box_public_key());
            challenge["macBoxSignature"] = json!(identity.sign(&statement));
        }
    }
    send(sender, challenge).await;
    // With the signature, a phone that scanned the Mac's pairing code sends its pre-approval
    // (`pairToken`), only after this challenge proved the Mac's key. hostd checks nothing but its
    // shape and forwards it with the request: the app decides, and only for a phone this host
    // already admitted as the owner's.
    let (signature, pair_token) = match tokio::time::timeout(SIGNATURE_WAIT, receiver.recv()).await {
        Ok(Some(ChannelEvent::Data(bytes))) => {
            let reply = serde_json::from_slice::<Value>(&bytes).ok();
            let signature = reply
                .as_ref()
                .and_then(|v| v.get("signature").and_then(Value::as_str).map(str::to_owned))
                .ok_or(("bad_request", "expected {signature}".to_owned()))?;
            let pair_token =
                reply.as_ref().and_then(|v| v.get("pairToken")).and_then(Value::as_str).map(str::to_owned);
            if pair_token.as_deref().is_some_and(|token| !is_pair_token(token)) {
                return Err(("bad_request", "pairToken is 16 to 64 base64url characters".into()));
            }
            (signature, pair_token)
        }
        _ => return Err(("timeout", "no signature".into())),
    };
    let message =
        challenge_message(&pairing.mac_device_id, phone, &nonce, identity_key, approval_key, action);
    if !verify(identity_key, &message, &signature) {
        return Err(("unpaired", "the signature does not match the identity key".into()));
    }
    let mut trust = pairing.trust.clone();
    if action == "unpair" {
        let known = trust.borrow().as_ref().is_some_and(|t| t.knows_identity(phone, identity_key));
        if !known {
            return Err(("unpaired", "this device is not paired".into()));
        }
        pairing.push_keys.remove(phone);
        (pairing.emit)(Event::Unpaired { phone_device_id: phone.to_owned() });
        send(sender, json!({"ok": true})).await;
        return Ok(());
    }
    // Decide nothing before the app said which phones it approved: a paired
    // phone right after a hostd restart must not be asked again.
    let loaded =
        tokio::time::timeout(TRUST_WAIT, async { trust.wait_for(Option::is_some).await.map(|_| ()) }).await;
    match loaded {
        Ok(Ok(_)) => {}
        Ok(Err(_)) => return Err(("unavailable", "the app is gone".into())),
        Err(_) => return Err(("unavailable", "the Mac app has not loaded its paired iPhones yet".into())),
    }
    let mut asked = false;
    let result = tokio::time::timeout(APPROVAL_WAIT, async {
        loop {
            let current = trust.borrow_and_update().clone().unwrap_or_default();
            match current.standing(phone, identity_key, approval_key) {
                Standing::Trusted => return Ok(()),
                Standing::Denied => {
                    if asked {
                        pairing.limiter.lock().expect("limiter").denied(phone, identity_key, Instant::now());
                    }
                    return Err(("denied", "the Mac did not allow this iPhone".into()));
                }
                Standing::Unknown => {}
            }
            if !asked {
                let admitted = pairing.limiter.lock().expect("limiter").admit(
                    phone,
                    identity_key,
                    &current,
                    Instant::now(),
                );
                if let Err(wait) = admitted {
                    return Err((
                        "rate_limited",
                        format!("the Mac asked about this iPhone recently; try again in {}", wait_text(wait)),
                    ));
                }
                asked = true;
                let registered_at_ms = match &pairing.registration {
                    Some(lookup) => {
                        tokio::time::timeout(REGISTRATION_WAIT, lookup(phone.to_owned())).await.ok().flatten()
                    }
                    None => None,
                };
                (pairing.emit)(Event::PairRequest {
                    phone_device_id: phone.to_owned(),
                    name: name.clone(),
                    identity_key: identity_key.to_owned(),
                    approval_key: approval_key.to_owned(),
                    registered_at_ms,
                    pair_token: pair_token.clone(),
                });
                send(sender, json!({"pending": true})).await;
            }
            if trust.changed().await.is_err() {
                return Err(("unavailable", "the app is gone".into()));
            }
        }
    })
    .await;
    match result {
        Ok(Ok(())) => {
            if let Some(push_key) = push_key {
                pairing.push_keys.set(phone, identity_key, &push_key);
            }
            send(sender, json!({"ok": true})).await;
            Ok(())
        }
        Ok(Err(refused)) => Err(refused),
        Err(_) => Err(("timeout", "nobody answered the Mac's prompt".into())),
    }
}

/// `pushKey` with `pushKeySignature` from `auth` args: `None` when the phone
/// sent none; refused when either is malformed or the identity key did not
/// sign `cmux-mobile-push-key-v1 \0 mac \0 phone \0 pushKey`.
pub fn push_key_arg(
    args: &Value,
    mac: &str,
    phone: &str,
    identity_key: &str,
) -> Result<Option<String>, Refused> {
    let text = |key: &str| args.get(key).and_then(Value::as_str).unwrap_or_default();
    let (push_key, signature) = (text("pushKey"), text("pushKeySignature"));
    if push_key.is_empty() && signature.is_empty() {
        return Ok(None);
    }
    if !is_point(push_key) || crate::seal::public_key_hex(push_key).is_err() {
        return Err(("bad_request", "pushKey must be a 65-byte uncompressed P-256 point as hex".into()));
    }
    if !verify(identity_key, &crate::seal::push_key_message(mac, phone, push_key), signature) {
        return Err(("bad_request", "pushKeySignature does not match the identity key".into()));
    }
    Ok(Some(push_key.to_owned()))
}

async fn send(sender: &ChannelSender, value: Value) {
    let _ = sender.send(Bytes::from(value.to_string())).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_challenge_is_fixed() {
        // The same vector is in the phone's LinkAuthTests.
        use ring::digest::{SHA256, digest};
        let m = challenge_message("mac-1", "phone-1", "n0", "04aa", "04bb", "pair");
        assert_eq!(&m[..25], b"cmux-mobile-link-auth-v1\0");
        let hex: String = digest(&SHA256, &m).as_ref().iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "9b706236232d90e6548bf7de5c624845d5209a65bb08dba15e4561b85fd26ae2");
    }

    #[tokio::test]
    async fn waiters_follow_every_running_auth() {
        // No auth yet: refused at once.
        let link = LinkAuth::default();
        assert!(!link.paired().await);
        // Two auths running; the first fails, the second passes: the waiter is served.
        link.begin();
        link.begin();
        let waiter = {
            let link = std::sync::Arc::new(link);
            let held = std::sync::Arc::clone(&link);
            (tokio::spawn(async move { held.paired().await }), link)
        };
        waiter.1.end(false);
        tokio::task::yield_now().await;
        assert!(!waiter.0.is_finished());
        waiter.1.end(true);
        assert!(waiter.0.await.unwrap());
        // Paired holds for the link: a later failed auth (an unpair) changes nothing.
        waiter.1.begin();
        waiter.1.end(false);
        assert!(waiter.1.is_authenticated());
        // The last running auth failing refuses the waiters.
        let other = LinkAuth::default();
        other.begin();
        other.end(false);
        assert!(!other.paired().await);
    }

    fn denied(id: &str, key: &str) -> DeviceTrust {
        DeviceTrust {
            devices: vec![],
            denied: vec![DeniedDevice { id: id.into(), identity_key: key.into() }],
        }
    }

    #[test]
    fn a_push_key_counts_only_with_the_identity_keys_signature() {
        let v: Value = serde_json::from_str(include_str!("../tests/fixtures/seal-vectors.json")).unwrap();
        let t = |k: &str| v[k].as_str().unwrap().to_owned();
        let (mac, phone, identity) = (t("mac"), t("phone"), t("phoneIdentityKey"));
        let args = json!({"pushKey": t("phonePushKey"), "pushKeySignature": t("pushKeySignature")});
        assert_eq!(push_key_arg(&args, &mac, &phone, &identity).unwrap(), Some(t("phonePushKey")));
        // None sent: none kept.
        assert_eq!(push_key_arg(&json!({}), &mac, &phone, &identity).unwrap(), None);
        // Signed for another Mac or phone, or by another key: refused.
        assert!(push_key_arg(&args, "other-mac", &phone, &identity).is_err());
        assert!(push_key_arg(&args, &mac, "other-phone", &identity).is_err());
        assert!(push_key_arg(&args, &mac, &phone, &t("macIdentityKey")).is_err());
        // A key without its signature, or not a point: refused.
        assert!(push_key_arg(&json!({"pushKey": t("phonePushKey")}), &mac, &phone, &identity).is_err());
        assert!(
            push_key_arg(
                &json!({"pushKey": "04", "pushKeySignature": t("pushKeySignature")}),
                &mac,
                &phone,
                &identity
            )
            .is_err()
        );
    }

    #[test]
    fn a_bad_push_key_is_refused_by_itself() {
        // `auth` ignores it (`unwrap_or_else`): the pairing goes on without sealed pushes.
        let v: Value = serde_json::from_str(include_str!("../tests/fixtures/seal-vectors.json")).unwrap();
        let t = |k: &str| v[k].as_str().unwrap().to_owned();
        let bad = json!({"pushKey": "04", "pushKeySignature": t("pushKeySignature")});
        let kept = push_key_arg(&bad, &t("mac"), &t("phone"), &t("phoneIdentityKey")).unwrap_or(None);
        assert_eq!(kept, None);
    }

    #[test]
    fn the_mac_identity_carries_its_box_key() {
        let v: Value = serde_json::from_str(include_str!("../tests/fixtures/seal-vectors.json")).unwrap();
        let t = |k: &str| v[k].as_str().unwrap().to_owned();
        let identity = MacIdentity::from_raw(&t("macIdentityScalar"), &t("macIdentityKey")).unwrap();
        assert_eq!(identity.box_public_key(), t("macBoxKey"));
        let fresh = MacIdentity::generate().unwrap();
        assert_ne!(fresh.box_public_key(), identity.box_public_key());
        assert!(verify(fresh.public_key(), b"m", &fresh.sign(b"m").unwrap()));
    }

    #[test]
    fn registration_dates_become_epoch_millis() {
        assert_eq!(epoch_millis("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(epoch_millis("2026-10-14T07:12:09.681Z"), Some(1_791_961_929_681));
        assert_eq!(epoch_millis("2000-02-29T12:00:00.5+00:00"), Some(951_825_600_500));
        assert_eq!(epoch_millis("2026-10-14 07:12:09Z"), None);
        assert_eq!(epoch_millis("2026-10-14T07:12:09+02:00"), None);
    }

    #[test]
    fn new_keys_ask_a_bounded_number_of_times() {
        let mut limiter = PromptLimiter::default();
        let none = DeviceTrust::default();
        let t0 = Instant::now();
        for key in ["k1", "k2", "k3"] {
            assert!(limiter.admit("p", key, &none, t0).is_ok());
        }
        // The same key again is no new key; a fourth key waits for the window.
        assert!(limiter.admit("p", "k1", &none, t0).is_ok());
        let wait = limiter.admit("p", "k4", &none, t0).unwrap_err();
        assert_eq!(wait, PROMPT_WINDOW);
        assert!(limiter.admit("p", "k4", &none, t0 + PROMPT_WINDOW).is_ok());
        // All phones together: at most PROMPTS_PER_ACCOUNT new keys per window.
        let mut limiter = PromptLimiter::default();
        for n in 0..PROMPTS_PER_ACCOUNT {
            assert!(limiter.admit(&format!("p{n}"), "k", &none, t0).is_ok());
        }
        assert!(limiter.admit("other", "k", &none, t0).is_err());
    }

    #[test]
    fn a_refusal_silences_that_device_whatever_key() {
        let mut limiter = PromptLimiter::default();
        let none = DeviceTrust::default();
        let t0 = Instant::now();
        assert!(limiter.admit("p", "k1", &none, t0).is_ok());
        limiter.denied("p", "k1", t0);
        assert_eq!(limiter.admit("p", "k2", &none, t0).unwrap_err(), DENY_COOLDOWN);
        // Another phone is not affected; this one asks again after the cooldown.
        assert!(limiter.admit("q", "k2", &none, t0).is_ok());
        assert!(limiter.admit("p", "k2", &none, t0 + DENY_COOLDOWN).is_ok());
        // A refusal seen only in the app's list (the request's channel was gone).
        let mut limiter = PromptLimiter::default();
        assert!(limiter.admit("p", "k1", &none, t0).is_ok());
        assert!(limiter.admit("p", "k2", &denied("p", "k1"), t0).is_err());
        // A refusal of a key this hostd never asked about (an older run) starts nothing.
        let mut limiter = PromptLimiter::default();
        assert!(limiter.admit("p", "k2", &denied("p", "k0"), t0).is_ok());
    }

    #[tokio::test]
    async fn only_so_many_channels_wait_behind_auth() {
        let link = std::sync::Arc::new(LinkAuth::default());
        assert_eq!(link.gate().await, Gate::Unpaired);
        assert!(link.try_begin());
        assert!(!link.try_begin(), "one auth at a time");
        let waiters: Vec<_> = (0..MAX_WAITERS)
            .map(|_| {
                let link = std::sync::Arc::clone(&link);
                tokio::spawn(async move { link.gate().await })
            })
            .collect();
        while link.waiters.load(std::sync::atomic::Ordering::SeqCst) < MAX_WAITERS {
            tokio::task::yield_now().await;
        }
        assert_eq!(link.gate().await, Gate::Busy);
        link.end(true);
        for waiter in waiters {
            assert_eq!(waiter.await.unwrap(), Gate::Paired);
        }
        assert!(link.try_begin(), "a paired link may unpair");
    }

    #[test]
    fn standing_needs_the_same_id_and_both_keys() {
        let trust = DeviceTrust {
            devices: vec![TrustedDevice {
                id: "p".into(),
                identity_key: "i".into(),
                approval_key: "a".into(),
            }],
            denied: vec![DeniedDevice { id: "q".into(), identity_key: "i".into() }],
        };
        assert_eq!(trust.standing("p", "i", "a"), Standing::Trusted);
        assert_eq!(trust.standing("p", "i", "b"), Standing::Unknown);
        assert_eq!(trust.standing("x", "i", "a"), Standing::Unknown);
        assert_eq!(trust.standing("q", "i", "a"), Standing::Denied);
        // A new identity key (the phone signed out and in) asks again.
        assert_eq!(trust.standing("q", "j", "a"), Standing::Unknown);
    }
}
