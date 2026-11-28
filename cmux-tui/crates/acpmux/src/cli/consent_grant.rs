//! Control and Screen consent the owner turns on or off for this machine from his own cmux app on
//! another machine (Leo, 2026-11-15: "yeah just change it pls"), with no approve or deny prompt
//! between his own signed-in devices (Leo, 2026-11-16, on "you approve each one": "it's too many
//! [...] steps").
//!
//! Trust design:
//! - The signer is the owner Mac's approver key (`hub/mac_approvers.rs`): P-256 in that Mac's
//!   Secure Enclave, used only by the signed cmux app, which signs a grant only after the person's
//!   own gesture and Touch ID or password. An agent, a shell or the daemon on that Mac cannot make
//!   it sign.
//! - This machine checks a grant only against keys it pinned itself, in its account-wide consent
//!   authority (`grantors.json` beside `consent.json`, private state). It pins one key with no
//!   prompt: its OWN app's (`_acpmux/mac_approver_set`, from the person-proven app on this
//!   machine), for [`ENROLL_WINDOW_MS`] after a step the person takes here (a sign-in, a join line,
//!   or Refresh trusted Macs) ([`open_window`], [`pin_enrolled`]). Every other Mac's key needs the
//!   person's one-time confirm in the cmux app here (`_acpmux/consent_grantor_trust`), from a
//!   pending ask (`grantor-ask.json`, at most [`MAX_ASKS`]) once its four words match the ones that
//!   Mac shows. An ask comes from that Mac's first grant, or from the key a listed peer reported
//!   during a collection ([`note_reported`]). No peer, carrier message, CLI or platform answer pins
//!   a key: a peer's daemon, or an agent running as it, can report any key.
//! - Unpinning a key takes back what it signed: its records and its account policy are dropped and
//!   `consent.json` is written again ([`trust`]); [`recompute`] counts only grantors still pinned.
//! - The platform, the relay, the machine credential and the carrier only carry grants. They hold
//!   no pinned key, so they can drop, delay or replay one: a replay is refused (the last accepted
//!   `issuedAt` per grantor and scope), a per-machine grant lives at most 5 minutes, and a key they
//!   put in an ask fails the person's word check.
//! - A grant names one machine (its platform machine id and its node key, the hub `daemonId`) or,
//!   with `*` for both, every machine of the account (the account policy, `account-policy.json`,
//!   kept until a newer one: it must reach machines that were offline or joined later, so its
//!   expiry is not checked). It names the account (hub user id) both machines are joined as, and a
//!   change for control and for screen. Per surface, the person's own setting here wins (sticky,
//!   On or Off); else the newer of the grant for this machine and the account policy; else none
//!   ([`recompute`]). `consent.json` keeps that effective value, so the gates read it unchanged.
//! - Once this machine is joined as another account, what was granted for the old one reads as
//!   not given ([`super::machine_consent::for_account`]); pins and policy count only for their
//!   account.
//! - What is granted lives on this machine's disk, in the OS account's consent authority, keyed to
//!   the account and this enrolled machine: never to a session, a process or a build. A daemon
//!   restart, an app update or a replaced daemon reads the same grant (Leo, 2026-11-16: "i dont
//!   want to have to click share this mac allow every single time when screen sharing").
//! - A screen share reaches this machine from the device hub as a viewer device of the account.
//!   [`screen_auto`] (`_acpmux/consent_screen_auto`) tells the app here whether it may skip its
//!   per-connect prompt: only when this machine is joined, the effective consent for the surface
//!   is on (local, machine or account) and the viewer's hub user is this machine's account. The
//!   viewer's identity comes from the device hub, so a compromised hub could ask as a device of
//!   the account once consent is on: the same exposure as the mesh adding a node to the book. The
//!   grant itself still cannot be forged, and turning consent off here ends it.
//! - Every outcome, accepted or refused, every pin and every local change is a line of
//!   `grants.jsonl`.
//!
//! What this does not change, and what it leaves:
//! - A process running as this machine's OS user (ssh as that user too) can already write
//!   `consent.json`; this adds no new path for it.
//! - An account grant is long-lived: a machine offline when a newer account Off was signed still
//!   takes an older account On replayed to it, until the Off reaches it (the counter refuses an
//!   older one only after a newer one arrived).
//! - With consent on, the gates admit any dialer the platform's hub book lists for the account:
//!   a platform that adds a node reaches what consent opened (the mesh's own exposure, amplified).
//! - [`screen_auto`]'s requester identity comes from the device hub.
//! - A machine with no cmux app (a Linux machine) has no pin path yet: it has no own app key, and
//!   the ask is answered only from the app's person-proven connection; it takes no grant.
//! - The platform supplies the list of machines a switch shows, so it can confuse which of the
//!   person's own pinned machines a row names; it cannot reach a machine that did not pin the key.

use super::cloud_join::{ConsentState, GrantedBy, HeldLock};
use super::machine_consent::Authority;
use crate::hub::approvers::{fingerprint, hex};
use anyhow::Result;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::path::Path;

/// The domain the signed bytes start with ([`message`]).
pub const DOMAIN: &str = "acpmux-consent-grant-v1";
/// The longest a grant message lives (`expiresAt - issuedAt`), in ms.
pub const MAX_LIFETIME_MS: u64 = 300_000;
/// How far ahead of this machine's clock a grant's `issuedAt` may be, in ms.
pub const MAX_AHEAD_MS: u64 = 60_000;
/// At most this many pinned grantors.
pub const MAX_GRANTORS: usize = 16;
/// The grant log keeps this many lines that are not refusals or asks, newest last.
pub const MAX_LOG_LINES: usize = 200;
/// ... and, apart from those, this many refusal and ask lines, so a flood of refused grants
/// never evicts a grant or a revoke.
pub const MAX_NOISY_LOG_LINES: usize = 50;
/// At most this many pending asks, newest last; a new one replaces the oldest.
pub const MAX_ASKS: usize = 8;
/// A status shows this many of the newest log lines.
pub const STATUS_LOG_LINES: usize = 20;
/// The longest request one carrier circuit takes.
pub const MAX_REQUEST_BYTES: usize = 8 * 1024;

pub const MALFORMED: &str = "grant.malformed";
pub const NOT_JOINED: &str = "grant.not_joined";
pub const ACCOUNT: &str = "grant.account";
pub const TARGET: &str = "grant.target";
pub const EXPIRED: &str = "grant.expired";
pub const UNPINNED: &str = "grant.unpinned";
pub const SIGNATURE: &str = "grant.signature";
pub const REPLAYED: &str = "grant.replayed";
/// Another consent change held the authority's lock past a short wait.
pub const BUSY: &str = "grant.busy";
/// The authority's files could not be read or written.
pub const STORE: &str = "grant.store";

/// An account-wide grant `_acpmux/consent_account_set` was given is not one this machine's own
/// app key signed.
pub const NOT_OWN: &str = "grant.not_own";

/// The `machineId` and `nodeKey` of an account-wide grant.
pub const ANY: &str = "*";
/// How long after a person step here this machine's own app key is pinned with no prompt, in ms.
pub const ENROLL_WINDOW_MS: u64 = 60_000;

const GRANTORS: &str = "grantors.json";
const ASK: &str = "grantor-ask.json";
const LOG: &str = "grants.jsonl";
const POLICY: &str = "account-policy.json";
const MACHINE_GRANTS: &str = "machine-grants.json";
const WINDOW: &str = "trust-window.json";

/// What a grant does to one surface.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Change {
    On,
    Off,
    Keep,
    /// Drops this machine's per-machine record of the surface: the account policy decides again.
    /// In an account grant (both surfaces), the sign-in's default On: it applies as On only on a
    /// machine that keeps no account policy for the account yet, so an automatic sign-in never
    /// undoes an Off the person set from another Mac.
    Default,
}

impl Change {
    pub fn word(self) -> &'static str {
        match self {
            Change::On => "on",
            Change::Off => "off",
            Change::Keep => "keep",
            Change::Default => "default",
        }
    }

    fn parse(word: &str) -> Option<Self> {
        match word {
            "on" => Some(Change::On),
            "off" => Some(Change::Off),
            "keep" => Some(Change::Keep),
            "default" => Some(Change::Default),
            _ => None,
        }
    }

    /// On or Off; None for keep and default.
    fn value(self) -> Option<bool> {
        match self {
            Change::On => Some(true),
            Change::Off => Some(false),
            Change::Keep | Change::Default => None,
        }
    }

    /// What a kept account policy says for a surface: a default (the sign-in's) is On.
    fn policy_value(self) -> Option<bool> {
        match self {
            Change::Default => Some(true),
            change => change.value(),
        }
    }

    /// The word an account policy reports for a surface (`accountPolicy`): on or off.
    fn policy_word(self) -> &'static str {
        if self.policy_value() == Some(true) { "on" } else { "off" }
    }
}

/// A parsed grant (the contract's wire shape, camelCase JSON).
#[derive(Clone, Debug)]
pub struct Grant {
    pub grantor: String,
    pub account: String,
    pub machine_id: String,
    pub node_key: String,
    pub control: Change,
    pub screen: Change,
    pub issued_at: u64,
    pub expires_at: u64,
    /// Raw `r || s`, 64 bytes.
    pub signature: Vec<u8>,
    /// Not signed: the key an ask shows, when the grantor is not pinned.
    pub public_key: Option<Vec<u8>>,
    /// Not signed: the name an ask shows.
    pub name: String,
}

impl Grant {
    /// The bytes this grant's signature covers.
    pub fn message(&self) -> Vec<u8> {
        message(
            &self.grantor,
            &self.account,
            &self.machine_id,
            &self.node_key,
            self.control.word(),
            self.screen.word(),
            self.issued_at,
            self.expires_at,
        )
    }

    /// The sign-in's default account grant: both surfaces `default`, signed with no gesture. It
    /// ranks below every explicit account grant and every per-machine record.
    pub fn is_default(&self) -> bool {
        self.account_wide() && self.control == Change::Default
    }

    /// Whether this grant is for every machine of the account (`*`).
    pub fn account_wide(&self) -> bool {
        self.machine_id == ANY
    }

    /// The change for `surface` (`control` or `screen`).
    fn change(&self, surface: &str) -> Change {
        if surface == "control" { self.control } else { self.screen }
    }

    /// The counter this grant is checked against: one per grantor for per-machine grants, one for
    /// its explicit account-wide grants and one for its sign-in defaults, so no kind holds another
    /// back. SECURITY: a default that arrives first never makes the same Mac's older Off replayed.
    fn seq_key(&self) -> String {
        if self.is_default() {
            format!("{}/{ANY}/default", self.grantor)
        } else if self.account_wide() {
            format!("{}/{ANY}", self.grantor)
        } else {
            self.grantor.clone()
        }
    }
}

/// The signed bytes: [`DOMAIN`], then each part after one NUL byte, numbers as decimal ASCII.
#[allow(clippy::too_many_arguments)]
pub fn message(
    grantor: &str,
    account: &str,
    machine_id: &str,
    node_key: &str,
    control: &str,
    screen: &str,
    issued_at: u64,
    expires_at: u64,
) -> Vec<u8> {
    let (issued, expires) = (issued_at.to_string(), expires_at.to_string());
    let mut out = DOMAIN.as_bytes().to_vec();
    for part in [grantor, account, machine_id, node_key, control, screen, &issued, &expires] {
        out.push(0);
        out.extend_from_slice(part.as_bytes());
    }
    out
}

/// Why a grant was refused: a reason code, a line for the person, and the four words of the key
/// an ask recorded ([`UNPINNED`] only).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub reason: &'static str,
    pub error: String,
    pub words: Option<[&'static str; 4]>,
}

impl Refusal {
    fn new(reason: &'static str, error: impl Into<String>) -> Self {
        Self { reason, error: error.into(), words: None }
    }

    /// The carrier's answer: `{ok: false, reason, error, words?}`.
    pub fn answer(&self) -> Value {
        let mut answer = json!({"ok": false, "reason": self.reason, "error": self.error});
        if let (Some(words), Some(fields)) = (self.words, answer.as_object_mut()) {
            fields.insert("words".into(), json!(words));
        }
        answer
    }
}

/// The machine a grant must name: the account it is joined as (None when it is not joined or its
/// join is revoked), its platform machine id and its node key (hub `daemonId`), and its name.
#[derive(Clone, Debug, Default)]
pub struct Target {
    pub account: Option<String>,
    pub machine_id: Option<String>,
    pub node_key: Option<String>,
    pub name: Option<String>,
    /// This machine's own app key (`_acpmux/mac_approver_set`), which its status reports to its
    /// peers' enrollment.
    pub own_grantor: Option<OwnGrantor>,
}

/// This machine's own app key, as the app here gave it (memory only).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OwnGrantor {
    /// [`grantor_id`] of the key.
    pub id: String,
    /// The 65-byte uncompressed P-256 point.
    pub public_key: Vec<u8>,
    pub name: String,
}

impl OwnGrantor {
    /// From `_acpmux/mac_approvers`' answer (`thisMac`), when the app gave a key.
    pub fn of(view: &Value) -> Option<Self> {
        let mac = view.get("thisMac").filter(|mac| !mac.is_null())?;
        let public_key = mac
            .get("publicKey")
            .and_then(Value::as_str)
            .and_then(unhex)
            .filter(|key| key.len() == 65 && key.first() == Some(&4))?;
        let name = mac.get("name").and_then(Value::as_str).unwrap_or_default().to_owned();
        Some(Self { id: grantor_id(&public_key), public_key, name })
    }

    /// `{id, publicKey, name}`, as a peer's enrollment reads it.
    pub fn json(&self) -> Value {
        json!({"id": self.id, "publicKey": hex(&self.public_key), "name": self.name})
    }
}

/// `grantors.json`: the pinned keys and, per grantor, the last `issuedAt` accepted.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Grantors {
    #[serde(default)]
    pub grantors: Vec<Pin>,
    #[serde(default)]
    pub seq: BTreeMap<String, u64>,
}

/// One pinned grantor: its id, its 65-byte P-256 key as hex, its name, the account it was pinned
/// for and when (ms).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pin {
    pub id: String,
    #[serde(rename = "publicKey")]
    pub public_key: String,
    #[serde(default)]
    pub name: String,
    pub account: String,
    #[serde(rename = "pinnedAt")]
    pub pinned_at: u64,
}

impl Grantors {
    /// The pin of `id` for `account`; a pin for another account counts as none.
    pub fn pinned(&self, id: &str, account: &str) -> Option<&Pin> {
        self.grantors.iter().find(|pin| pin.id == id && pin.account == account)
    }
}

/// `grantor-ask.json`: the one pending ask an unpinned grant left.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ask {
    pub id: String,
    #[serde(rename = "publicKey")]
    pub public_key: String,
    #[serde(default)]
    pub name: String,
    pub account: String,
    #[serde(default)]
    pub from: Option<String>,
    pub at: u64,
    pub words: Vec<String>,
}

impl Ask {
    fn of(key: &[u8], name: &str, account: &str, from: Option<&str>, now: u64) -> Self {
        Self {
            id: grantor_id(key),
            public_key: hex(key),
            name: bounded(name),
            account: account.to_owned(),
            from: from.map(bounded),
            at: now,
            words: words(key).iter().map(|w| (*w).to_owned()).collect(),
        }
    }
}

/// The pending asks (`grantor-ask.json`, `{"asks": [...]}`), oldest first. A file an older
/// build wrote holds one ask.
fn read_asks(root: &Path) -> Vec<Ask> {
    match read_json_opt::<Value>(&root.join(ASK)) {
        Some(value) if value.get("asks").is_some() => {
            serde_json::from_value(value.get("asks").cloned().unwrap_or_default())
                .unwrap_or_default()
        }
        Some(value) => serde_json::from_value::<Ask>(value).ok().into_iter().collect(),
        None => Vec::new(),
    }
}

fn write_asks(root: &Path, asks: &[Ask]) -> Result<()> {
    if asks.is_empty() {
        return Ok(remove(&root.join(ASK))?);
    }
    write_json(&root.join(ASK), &json!({ "asks": asks }))
}

/// Adds `ask` to the pending asks: one per grantor and account (a new one replaces the old), at
/// most [`MAX_ASKS`], the oldest dropped. The caller holds the lock.
fn record_ask(root: &Path, ask: Ask) -> Result<()> {
    let mut asks = read_asks(root);
    asks.retain(|kept| !(kept.id == ask.id && kept.account == ask.account));
    asks.push(ask);
    let skip = asks.len().saturating_sub(MAX_ASKS);
    let asks: Vec<Ask> = asks.into_iter().skip(skip).collect();
    write_asks(root, &asks)
}

/// Drops the pending asks of `id`. The caller holds the lock. True when one was dropped.
fn drop_asks(root: &Path, id: &str) -> Result<bool> {
    let mut asks = read_asks(root);
    let before = asks.len();
    asks.retain(|ask| ask.id != id);
    if asks.len() == before {
        return Ok(false);
    }
    write_asks(root, &asks)?;
    Ok(true)
}

/// `grantors.json` for a write: none yet is empty, but a file that exists and cannot be read
/// refuses, so a write never replaces the pins it could not read.
fn read_grantors_for_write(root: &Path) -> Result<Grantors> {
    let path = root.join(GRANTORS);
    if !path.try_exists()? {
        return Ok(Grantors::default());
    }
    Ok(serde_json::from_reader(crate::config::private_state_file(&path)?)?)
}

/// The grantor id of a key: `mac-` and the first 8 bytes of its SHA-256 as hex.
pub fn grantor_id(key: &[u8]) -> String {
    format!("mac-{}", fingerprint(key))
}

/// The four words a person compares for a key.
pub fn words(key: &[u8]) -> [&'static str; 4] {
    cmux_server_core::pairing::fingerprint_words(key)
}

/// Parses a grant; anything off is [`MALFORMED`].
pub fn parse(value: &Value) -> Result<Grant, Refusal> {
    let bad = |what: &str| Refusal::new(MALFORMED, format!("the grant is malformed ({what})"));
    let text = |field: &'static str| -> Result<String, Refusal> {
        value
            .get(field)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty() && s.len() <= 128 && !s.chars().any(char::is_control))
            .map(str::to_owned)
            .ok_or_else(|| bad(field))
    };
    let number = |field: &'static str| value.get(field).and_then(Value::as_u64).ok_or(bad(field));
    let change = |field: &'static str| {
        value.get(field).and_then(Value::as_str).and_then(Change::parse).ok_or(bad(field))
    };
    if value.get("v").and_then(Value::as_u64) != Some(1) {
        return Err(bad("v"));
    }
    let grantor = text("grantor")?;
    if !valid_grantor(&grantor) {
        return Err(bad("grantor"));
    }
    let account = text("account")?;
    let machine_id = text("machineId")?;
    let node_key = text("nodeKey")?;
    // `*` for both, or a machine and its node key.
    let account_wide = machine_id == ANY;
    if account_wide != (node_key == ANY) || (!account_wide && !node_key_bytes(&node_key)) {
        return Err(bad("nodeKey"));
    }
    let (control, screen) = (change("control")?, change("screen")?);
    if control == Change::Keep && screen == Change::Keep {
        return Err(bad("control and screen are both keep"));
    }
    // The account policy is the newest account grant, whole, so it names both surfaces.
    let sets = |change: Change| matches!(change, Change::On | Change::Off);
    let default = control == Change::Default && screen == Change::Default;
    if account_wide && !(sets(control) && sets(screen)) && !default {
        return Err(bad("an account grant sets control and screen on or off, or both default"));
    }
    let (issued_at, expires_at) = (number("issuedAt")?, number("expiresAt")?);
    let signature = value
        .get("signature")
        .and_then(Value::as_str)
        .and_then(unhex)
        .filter(|s| s.len() == 64)
        .ok_or(bad("signature"))?;
    let public_key = match value.get("publicKey") {
        None | Some(Value::Null) => None,
        Some(key) => Some(
            key.as_str()
                .and_then(unhex)
                .filter(|k| k.len() == 65 && k.first() == Some(&4))
                .ok_or(bad("publicKey"))?,
        ),
    };
    let name = value
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .chars()
        .filter(|c| !c.is_control())
        .take(64)
        .collect();
    Ok(Grant {
        grantor,
        account,
        machine_id,
        node_key,
        control,
        screen,
        issued_at,
        expires_at,
        signature,
        public_key,
        name,
    })
}

/// Whether `grant` holds for `target` under `grantors` at `now` (ms): the contract's checks in
/// its order, the first failure answering. An unpinned grantor's refusal carries the words of the
/// key an ask would show, when that key is the grantor's and signed the grant.
pub fn verify(
    grant: &Grant,
    target: &Target,
    grantors: &Grantors,
    now: u64,
) -> Result<(), Refusal> {
    let account = precheck(grant, target, now)?;
    let Some(pin) = grantors.pinned(&grant.grantor, account) else {
        let mut refusal = Refusal::new(
            UNPINNED,
            "this machine does not trust that Mac yet: allow it once in cmux here, after \
             checking its words",
        );
        refusal.words = ask_key(grant).map(|key| words(&key));
        return Err(refusal);
    };
    if !pin.key().is_some_and(|key| signed_by(grant, &key)) {
        return Err(Refusal::new(SIGNATURE, "the grant's signature is not the trusted Mac's"));
    }
    if grantors.seq.get(&grant.seq_key()).is_some_and(|last| grant.issued_at <= *last) {
        return Err(Refusal::new(REPLAYED, "the grant was already used or is older than one used"));
    }
    Ok(())
}

/// The checks of [`verify`] that need no store: joined, the account, the machine, the time.
/// The account it answers is this machine's.
fn precheck<'a>(grant: &Grant, target: &'a Target, now: u64) -> Result<&'a str, Refusal> {
    let Some(account) = target.account.as_deref() else {
        return Err(Refusal::new(NOT_JOINED, "this machine is not joined to an account"));
    };
    if grant.account != account {
        return Err(Refusal::new(ACCOUNT, "the grant is for another account than this machine's"));
    }
    if !grant.account_wide()
        && (target.machine_id.as_deref() != Some(grant.machine_id.as_str())
            || target.node_key.as_deref() != Some(grant.node_key.as_str()))
    {
        return Err(Refusal::new(TARGET, "the grant names another machine"));
    }
    // An account-wide grant is policy that must reach machines offline when it was made: only
    // its issue time is checked, and its counter bounds a replay.
    let lifetime_ok = grant.account_wide()
        || (grant.expires_at > now
            && grant
                .expires_at
                .checked_sub(grant.issued_at)
                .is_some_and(|lifetime| lifetime <= MAX_LIFETIME_MS));
    if !lifetime_ok || grant.issued_at > now.saturating_add(MAX_AHEAD_MS) {
        return Err(Refusal::new(EXPIRED, "the grant expired or is not valid yet"));
    }
    Ok(account)
}

impl Pin {
    fn key(&self) -> Option<Vec<u8>> {
        unhex(&self.public_key).filter(|k| k.len() == 65)
    }
}

/// The key an ask may show for `grant`: its `publicKey` hint, when that key's id is the grant's
/// grantor and it signed the grant.
pub fn ask_key(grant: &Grant) -> Option<Vec<u8>> {
    grant.public_key.clone().filter(|key| grantor_id(key) == grant.grantor && signed_by(grant, key))
}

pub(crate) fn signed_by(grant: &Grant, key: &[u8]) -> bool {
    ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, key)
        .verify(&grant.message(), &grant.signature)
        .is_ok()
}

/// Applies a grant: it is parsed and its account, machine and time checked first, then under the
/// authority's lock its pin, signature and counter; then the grantor's counter, the record (or the
/// account policy), the effective `consent.json` and the log. A refusal is logged too, and an
/// unpinned grant whose key checks out leaves a pending ask. `from` names the machine that carried
/// it (a host the hub lists).
#[cfg_attr(not(feature = "hub-carrier"), allow(dead_code))] // the carrier's consent service
pub(crate) fn apply(
    authority: &Authority,
    value: &Value,
    target: &Target,
    from: Option<&str>,
    now: u64,
) -> Result<super::cloud_join::Consent, Refusal> {
    let store = || Refusal::new(STORE, "this machine's consent store is unavailable");
    authority.prepare().map_err(|_| store())?;
    let root = authority.root();
    // What needs no store is checked before the lock: a refusal then logs only if the lock is
    // free now, so a flood of bad grants never holds up a change.
    let early = parse(value).and_then(|grant| precheck(&grant, target, now).map(|_| grant));
    let grant = match early {
        Ok(grant) => grant,
        Err(refusal) => {
            if let Ok(_lock) = authority.lock() {
                let by = value.get("grantor").and_then(Value::as_str).filter(|g| valid_grantor(g));
                let name = value.get("name").and_then(Value::as_str);
                let account = value.get("account").and_then(Value::as_str);
                log_refused(root, by.unwrap_or("unknown"), name, &refusal, from, account, now);
            }
            return Err(refusal);
        }
    };
    let _lock = lock_waiting(authority)
        .map_err(|_| Refusal::new(BUSY, "a consent change is in progress here"))?;
    let mut grantors = read_grantors_for_write(root).map_err(|_| store())?;
    if let Err(refusal) = verify(&grant, target, &grantors, now) {
        if refusal.reason == UNPINNED
            && let Some(key) = ask_key(&grant)
        {
            let ask = Ask::of(&key, &grant.name, &grant.account, from, now);
            if record_ask(root, ask).is_ok() {
                let mut line = event(now, "ask", &grant.grantor);
                put(&mut line, "name", Some(grant.name.as_str()));
                put(&mut line, "from", from);
                put(&mut line, "account", Some(grant.account.as_str()));
                let _ = append_log(root, Value::Object(line));
            }
        }
        let account = Some(grant.account.as_str());
        log_refused(root, &grant.grantor, Some(&grant.name), &refusal, from, account, now);
        return Err(refusal);
    }
    let name = grantors
        .pinned(&grant.grantor, &grant.account)
        .map(|pin| pin.name.clone())
        .unwrap_or_default();
    let mut stale = false;
    if grant.account_wide() {
        // The newest account policy for this account is kept whole, signature included, so this
        // machine can hand it on to a peer that enrolls later (`op: "policy"`). An older one
        // (another grantor's newer policy is kept) changes nothing.
        // SECURITY: the sign-in's default On (both `default`) takes only where no policy for the
        // account is kept yet, and any explicit grant replaces it (`replaces`).
        let kept = read_policy(root).filter(|(kept, _)| kept.account == grant.account);
        let newer = replaces(kept.as_ref().map(|(kept, _)| kept), &grant);
        if newer {
            write_json(&root.join(POLICY), &json!({"grant": value, "at": now}))
                .map_err(|_| store())?;
        }
        stale = !newer;
    } else {
        let mut records: MachineGrants = read_json(&root.join(MACHINE_GRANTS));
        for (surface, record) in
            [("control", &mut records.control), ("screen", &mut records.screen)]
        {
            match grant.change(surface) {
                Change::Keep => {}
                Change::Default => *record = None,
                change => {
                    *record = change.value().map(|on| Record {
                        on,
                        issued_at: grant.issued_at,
                        grantor: grant.grantor.clone(),
                        account: grant.account.clone(),
                        at: now,
                    });
                }
            }
        }
        write_json(&root.join(MACHINE_GRANTS), &records).map_err(|_| store())?;
    }
    let turns_on = |change: Change| {
        change == Change::On || (grant.account_wide() && change == Change::Default)
    };
    let granted = !stale && (turns_on(grant.control) || turns_on(grant.screen));
    let consent = rewrite_consent(authority, Some(&grant.account), granted.then_some(now))
        .map_err(|_| store())?;
    // The counter advances only after the record and `consent.json` are written: an apply cut
    // short before then leaves the same grant acceptable again, so an interrupted Off can be
    // retried instead of being refused as a replay with the old On still in effect.
    grantors.seq.insert(grant.seq_key(), grant.issued_at);
    write_json(&root.join(GRANTORS), &grantors).map_err(|_| store())?;
    let scope = if grant.account_wide() { "account" } else { "machine" };
    let log = |what: &str, surface: Option<&str>| {
        let mut line = event(now, what, &grant.grantor);
        put(&mut line, "name", Some(name.as_str()).filter(|n| !n.is_empty()));
        put(&mut line, "surface", surface);
        put(&mut line, "scope", Some(scope));
        put(&mut line, "from", from);
        put(&mut line, "account", Some(grant.account.as_str()));
        let _ = append_log(root, Value::Object(line));
    };
    if stale {
        log("stale", None);
        return Ok(consent);
    }
    for surface in ["control", "screen"] {
        let what = match grant.change(surface) {
            Change::On => "grant",
            Change::Off => "revoke",
            Change::Default if grant.account_wide() => "grant",
            Change::Default => "default",
            Change::Keep => continue,
        };
        log(what, Some(surface));
    }
    Ok(consent)
}

/// Writes `consent.json` again from its local settings, this machine's records and the account
/// policy ([`recompute`]), for `account` when given; `granted_at` when a grant just turned
/// something on. The caller holds the lock.
fn rewrite_consent(
    authority: &Authority,
    account: Option<&str>,
    granted_at: Option<u64>,
) -> Result<super::cloud_join::Consent> {
    let mut consent = authority.consent();
    consent.control_local = local_of(&consent, "control");
    consent.screen_local = local_of(&consent, "screen");
    recompute(authority.root(), &mut consent, account);
    if let Some(at) = granted_at {
        consent.granted_at = Some(at.to_string());
    }
    crate::config::write_atomic(
        &authority.root().join("consent.json"),
        &serde_json::to_vec(&consent)?,
    )?;
    Ok(consent)
}

/// One surface's signed setting: on or off, when it was issued, by which grantor for which
/// account, and when it was applied here (ms).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    pub on: bool,
    #[serde(rename = "issuedAt")]
    pub issued_at: u64,
    pub grantor: String,
    pub account: String,
    pub at: u64,
}

/// `machine-grants.json`: the per-machine grants' records, per surface.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct MachineGrants {
    #[serde(default)]
    control: Option<Record>,
    #[serde(default)]
    screen: Option<Record>,
}

/// The person's own setting of `surface` here. A file an older build wrote (no source) holds it
/// as the value itself: granted there was the person's own On. Its none is never set, not an
/// Off, so the person's own machines are still let in (`machine_record::joined_consent_allows`).
pub(crate) fn local_of(consent: &super::cloud_join::Consent, surface: &str) -> Option<bool> {
    let (local, source, state, by) = if surface == "control" {
        (
            consent.control_local,
            &consent.control_source,
            &consent.control,
            &consent.control_granted_by,
        )
    } else {
        (consent.screen_local, &consent.screen_source, &consent.screen, &consent.screen_granted_by)
    };
    if local.is_some() || source.is_some() {
        return local;
    }
    // A file an older build wrote is the person's own record: its granted is a local On; its
    // none is never set (joining is the consent for the person's own machines). No file at all
    // is no setting.
    if !consent.on_disk || by.is_some() {
        return None;
    }
    matches!(state, ConsentState::Granted).then_some(true)
}

/// The account policy kept here and when it was applied, parsed.
fn read_policy(root: &Path) -> Option<(Grant, u64)> {
    let kept: Value = read_json_opt(&root.join(POLICY))?;
    let at = kept.get("at").and_then(Value::as_u64).unwrap_or_default();
    parse(kept.get("grant")?).ok().map(|grant| (grant, at))
}

/// The account policy kept here for `account`, whole, as a peer verifies it.
#[cfg_attr(not(feature = "hub-carrier"), allow(dead_code))] // the carrier's consent service
pub(crate) fn policy_grant(root: &Path, account: Option<&str>) -> Option<Value> {
    let kept: Value = read_json_opt(&root.join(POLICY))?;
    let grant = kept.get("grant")?;
    let parsed = parse(grant).ok()?;
    (account == Some(parsed.account.as_str())).then(|| grant.clone())
}

/// Whether account grant `grant` replaces the account policy `kept` for its account.
/// SECURITY: a sign-in default (no gesture) takes only where nothing is kept, and any explicit
/// grant replaces a kept default whatever its signing time: a default never wins over an Off the
/// person signed, in whichever order they arrive. Explicit grants order by signing time.
fn replaces(kept: Option<&Grant>, grant: &Grant) -> bool {
    if grant.is_default() {
        kept.is_none()
    } else {
        kept.is_none_or(|kept| kept.is_default() || grant.issued_at > kept.issued_at)
    }
}

/// Whether an account policy a peer handed (`op: "policy"`) would replace the one kept here for
/// `account`: the collection applies only those, so it never logs the same stale policy again.
#[cfg_attr(not(feature = "hub-carrier"), allow(dead_code))] // the carrier's consent service
pub(crate) fn policy_replaces(authority: &Authority, account: &str, handed: &Value) -> bool {
    let Ok(handed) = parse(handed) else { return false };
    let kept = read_policy(authority.root()).filter(|(kept, _)| kept.account == account);
    handed.account_wide() && replaces(kept.as_ref().map(|(kept, _)| kept), &handed)
}

/// When the account policy kept here for `account` was issued (the tests read it).
#[cfg(test)]
pub(crate) fn policy_issued_at(authority: &Authority, account: &str) -> Option<u64> {
    read_policy(authority.root())
        .filter(|(grant, _)| grant.account == account)
        .map(|(grant, _)| grant.issued_at)
}

/// Writes the effective `control` and `screen` into `consent` from the person's own setting here
/// (`*Local`, which wins), else the newer of this machine's record and the account policy (a
/// record wins a tie), else none; with each one's source and, while a grant turns it on, who
/// granted it. With `account`, only grants for it count. The caller holds the lock.
pub(crate) fn recompute(
    root: &Path,
    consent: &mut super::cloud_join::Consent,
    account: Option<&str>,
) {
    // A record or policy counts only while its grantor is still pinned for its account: an unpin
    // takes back what that Mac granted.
    let grantors: Grantors = read_json(&root.join(GRANTORS));
    let counts = |grantor: &str, grant_account: &str| {
        account.is_none_or(|account| account == grant_account)
            && grantors.pinned(grantor, grant_account).is_some()
    };
    let records: MachineGrants = read_json(&root.join(MACHINE_GRANTS));
    let policy = read_policy(root).filter(|(grant, _)| counts(&grant.grantor, &grant.account));
    for surface in ["control", "screen"] {
        let local = if surface == "control" { consent.control_local } else { consent.screen_local };
        let record = if surface == "control" { &records.control } else { &records.screen };
        let record = record.clone().filter(|record| counts(&record.grantor, &record.account));
        let account_record = policy.as_ref().and_then(|(grant, at)| {
            grant.change(surface).policy_value().map(|on| Record {
                on,
                issued_at: grant.issued_at,
                grantor: grant.grantor.clone(),
                account: grant.account.clone(),
                at: *at,
            })
        });
        // A sign-in default ranks below every per-machine record, whatever their signing times.
        let default = policy.as_ref().is_some_and(|(grant, _)| grant.is_default());
        let signed = match (record, account_record) {
            (Some(record), Some(policy)) if !default && policy.issued_at > record.issued_at => {
                Some((policy, "account"))
            }
            (Some(record), _) => Some((record, "machine")),
            (None, Some(policy)) => Some((policy, "account")),
            (None, None) => None,
        };
        let (on, source, by) = match (local, signed) {
            (Some(on), _) => (on, "local", None),
            (None, Some((record, source))) => {
                let by = record.on.then(|| GrantedBy {
                    grantor: record.grantor.clone(),
                    account: record.account.clone(),
                    at: record.at,
                });
                (record.on, source, by)
            }
            (None, None) => (false, "none", None),
        };
        let state = if on { ConsentState::Granted } else { ConsentState::None };
        if surface == "control" {
            consent.control = state;
            consent.control_granted_by = by;
            consent.control_source = Some(source.to_owned());
        } else {
            consent.screen = state;
            consent.screen_granted_by = by;
            consent.screen_source = Some(source.to_owned());
        }
    }
}

/// Logs a local consent change (`machine_consent_set`), `by: "local"`: on, off, or cleared
/// (None, event `default`). The caller holds the lock.
pub(crate) fn log_local(authority: &Authority, surface: &str, local: Option<bool>) -> Result<()> {
    let what = match local {
        Some(true) => "grant",
        Some(false) => "revoke",
        None => "default",
    };
    let mut line = event(crate::store::now_ms(), what, "local");
    put(&mut line, "surface", Some(surface));
    append_log(authority.root(), Value::Object(line))
}

/// Opens this machine's enrollment window at `now`: for [`ENROLL_WINDOW_MS`] its own app key is
/// pinned with no prompt ([`pin_enrolled`]). Only a step the person takes here opens it: a
/// sign-in (a join or a follow), a join line, Refresh trusted Macs.
pub(crate) fn open_window(authority: &Authority, now: u64) -> Result<()> {
    authority.prepare()?;
    let _lock = lock_waiting(authority)?;
    let until = now.saturating_add(ENROLL_WINDOW_MS);
    write_json(&authority.root().join(WINDOW), &json!({"opened": now, "until": until}))
}

/// Whether the enrollment window is open at `now`.
#[cfg_attr(not(feature = "hub-carrier"), allow(dead_code))] // the carrier's consent service
pub(crate) fn window_open(authority: &Authority, now: u64) -> bool {
    read_json_opt::<Value>(&authority.root().join(WINDOW))
        .and_then(|window| Some((window.get("opened")?.as_u64()?, window.get("until")?.as_u64()?)))
        .is_some_and(|(opened, until)| opened <= now && now <= until)
}

/// Pins this machine's OWN app key (`key`, named `name`, the one `_acpmux/mac_approver_set` gave
/// from the person-proven app here) for `account` with no prompt, while the enrollment window is
/// open. True when it was not pinned before. Logs `pinned` with `via: "enroll"` and drops an ask
/// for the same key. Never call it with a key another machine reported: those become asks
/// ([`note_reported`]).
#[cfg_attr(not(feature = "hub-carrier"), allow(dead_code))] // the carrier's consent service
pub(crate) fn pin_enrolled(
    authority: &Authority,
    key: &[u8],
    name: &str,
    account: &str,
    now: u64,
) -> Result<bool, TrustError> {
    if key.len() != 65 || key.first() != Some(&4) {
        return Err(TrustError::Invalid("the key is not a P-256 point".into()));
    }
    if !window_open(authority, now) {
        return Err(TrustError::Invalid(
            "this machine's enrollment window is closed: allow the Mac in cmux here".into(),
        ));
    }
    authority.prepare().map_err(|_| TrustError::Store)?;
    let _lock = lock_waiting(authority).map_err(|_| TrustError::Store)?;
    let root = authority.root();
    let id = grantor_id(key);
    let mut grantors = read_grantors_for_write(root).map_err(|_| TrustError::Store)?;
    if grantors.pinned(&id, account).is_some() {
        return Ok(false);
    }
    grantors.grantors.retain(|pin| !(pin.id == id && pin.account == account));
    if grantors.grantors.len() >= MAX_GRANTORS {
        return Err(TrustError::Invalid(format!("at most {MAX_GRANTORS} trusted Macs")));
    }
    let name = bounded(name);
    grantors.grantors.push(Pin {
        id: id.clone(),
        public_key: hex(key),
        name: name.clone(),
        account: account.to_owned(),
        pinned_at: now,
    });
    write_json(&root.join(GRANTORS), &grantors).map_err(|_| TrustError::Store)?;
    drop_asks(root, &id).map_err(|_| TrustError::Store)?;
    let mut line = event(now, "pinned", &id);
    put(&mut line, "via", Some("enroll"));
    put(&mut line, "name", Some(name.as_str()).filter(|n| !n.is_empty()));
    put(&mut line, "account", Some(account));
    let _ = append_log(root, Value::Object(line));
    Ok(true)
}

/// A listed peer's carrier `status` answer (`status`, from the machine the book lists as `host`)
/// during an enrollment collection: the key its app reported (`ownGrantor`) becomes a pending
/// ask with its four words when it is for `account`, its id is its key's and it is not pinned
/// yet. Never a pin: a peer's daemon, or anything running as it, can report any key. The id
/// asked for, if one was.
#[cfg_attr(not(feature = "hub-carrier"), allow(dead_code))] // the carrier's consent service
pub(crate) fn note_reported(
    authority: &Authority,
    status: &Value,
    host: &str,
    account: &str,
    now: u64,
) -> Result<Option<String>, TrustError> {
    if status.get("account").and_then(Value::as_str) != Some(account) {
        return Ok(None);
    }
    let Some(own) = status.get("ownGrantor").filter(|own| own.is_object()) else {
        return Ok(None);
    };
    let Some(key) = own
        .get("publicKey")
        .and_then(Value::as_str)
        .and_then(unhex)
        .filter(|key| key.len() == 65 && key.first() == Some(&4))
    else {
        return Ok(None);
    };
    let id = grantor_id(&key);
    if own.get("id").and_then(Value::as_str) != Some(id.as_str()) {
        return Ok(None);
    }
    authority.prepare().map_err(|_| TrustError::Store)?;
    let _lock = lock_waiting(authority).map_err(|_| TrustError::Store)?;
    let root = authority.root();
    let grantors = read_grantors_for_write(root).map_err(|_| TrustError::Store)?;
    if grantors.pinned(&id, account).is_some() {
        return Ok(None);
    }
    let name = own.get("name").and_then(Value::as_str).unwrap_or_default();
    let known = read_asks(root).iter().any(|ask| ask.id == id && ask.account == account);
    record_ask(root, Ask::of(&key, name, account, Some(host), now))
        .map_err(|_| TrustError::Store)?;
    if !known {
        let mut line = event(now, "ask", &id);
        put(&mut line, "via", Some("peer"));
        put(&mut line, "name", Some(name).filter(|n| !n.is_empty()));
        put(&mut line, "from", Some(host));
        put(&mut line, "account", Some(account));
        let _ = append_log(root, Value::Object(line));
    }
    Ok(Some(id))
}

/// The account-wide grant `_acpmux/consent_account_set` takes: one this machine's own app key
/// (`own`) signed, for every machine (`*`). Anything else is refused before it is applied or
/// handed to a peer.
pub fn own_account_grant(value: &Value, own: Option<&OwnGrantor>) -> Result<Grant, Refusal> {
    let grant = parse(value)?;
    if !grant.account_wide() {
        return Err(Refusal::new(MALFORMED, "the grant is not for every machine (`*`)"));
    }
    let own = own.ok_or_else(|| Refusal::new(NOT_OWN, "the app here gave no key of its own"))?;
    if grant.grantor != own.id || !signed_by(&grant, &own.public_key) {
        return Err(Refusal::new(NOT_OWN, "the grant is not signed by this Mac's own app key"));
    }
    Ok(grant)
}

/// Why a trust change was not made.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum TrustError {
    /// The request does not match a pending ask, or no room is left: the caller's to fix.
    Invalid(String),
    Store,
}

/// `_acpmux/consent_grantor_trust {id, trusted}`: trusted pins the pending ask of `id` made for
/// `account`, this machine's account now; not trusted unpins `id`, takes back the records and the
/// account policy it signed (`consent.json` is written again, so the next circuit is refused
/// unless something else holds) and dismisses its asks. The caller proved the person on a local
/// connection.
pub(crate) fn trust(
    authority: &Authority,
    id: &str,
    trusted: bool,
    account: Option<&str>,
    now: u64,
) -> Result<Value, TrustError> {
    authority.prepare().map_err(|_| TrustError::Store)?;
    let _lock = lock_waiting(authority).map_err(|_| TrustError::Store)?;
    let root = authority.root();
    let asks = read_asks(root);
    let mut grantors = read_grantors_for_write(root).map_err(|_| TrustError::Store)?;
    if trusted {
        let ask = asks
            .into_iter()
            .find(|ask| ask.id == id && account == Some(ask.account.as_str()))
            .ok_or_else(|| {
                TrustError::Invalid(
                    "no pending ask from that Mac for the account this machine is joined as".into(),
                )
            })?;
        grantors.grantors.retain(|pin| !(pin.id == ask.id && pin.account == ask.account));
        if grantors.grantors.len() >= MAX_GRANTORS {
            return Err(TrustError::Invalid(format!("at most {MAX_GRANTORS} trusted Macs")));
        }
        grantors.grantors.push(Pin {
            id: ask.id.clone(),
            public_key: ask.public_key.clone(),
            name: ask.name.clone(),
            account: ask.account.clone(),
            pinned_at: now,
        });
        write_json(&root.join(GRANTORS), &grantors).map_err(|_| TrustError::Store)?;
        drop_asks(root, &ask.id).map_err(|_| TrustError::Store)?;
        let mut line = event(now, "pinned", &ask.id);
        put(&mut line, "name", Some(ask.name.as_str()));
        put(&mut line, "account", Some(ask.account.as_str()));
        let _ = append_log(root, Value::Object(line));
        return Ok(json!({"pinned": true, "id": ask.id, "words": ask.words}));
    }
    let before = grantors.grantors.len();
    grantors.grantors.retain(|pin| pin.id != id);
    let unpinned = grantors.grantors.len() != before;
    if unpinned {
        // The counter stays: a grant accepted before the unpin is never accepted again.
        write_json(&root.join(GRANTORS), &grantors).map_err(|_| TrustError::Store)?;
    }
    // Taken back on every unpin, a repeat included: an unpin cut short after the pin was
    // dropped but before its grants were finishes when the person tries again.
    take_back(authority, id, account).map_err(|_| TrustError::Store)?;
    if unpinned {
        let _ = append_log(root, Value::Object(event(now, "unpinned", id)));
    }
    let dismissed = drop_asks(root, id).map_err(|_| TrustError::Store)?;
    Ok(json!({"unpinned": unpinned, "dismissed": dismissed}))
}

/// Drops this machine's records and the account policy `id` signed, then writes `consent.json`
/// again for `account`. The caller holds the lock.
fn take_back(authority: &Authority, id: &str, account: Option<&str>) -> Result<()> {
    let root = authority.root();
    let mut records: MachineGrants = read_json(&root.join(MACHINE_GRANTS));
    let signed = |record: &Option<Record>| record.as_ref().is_some_and(|r| r.grantor == id);
    if signed(&records.control) || signed(&records.screen) {
        if signed(&records.control) {
            records.control = None;
        }
        if signed(&records.screen) {
            records.screen = None;
        }
        write_json(&root.join(MACHINE_GRANTS), &records)?;
    }
    if read_policy(root).is_some_and(|(grant, _)| grant.grantor == id) {
        remove(&root.join(POLICY))?;
    }
    rewrite_consent(authority, account, None).map(|_| ())
}

/// The account policy kept here for `account`, as a status shows it:
/// `{grantor, issuedAt, control, screen}`, or null.
fn account_policy(root: &Path, account: Option<&str>) -> Value {
    read_policy(root).filter(|(grant, _)| account == Some(grant.account.as_str())).map_or(
        Value::Null,
        |(grant, _)| {
            json!({"grantor": grant.grantor, "issuedAt": grant.issued_at,
                "control": grant.control.policy_word(), "screen": grant.screen.policy_word()})
        },
    )
}

/// `{"control": {on, source}, "screen": {on, source}}`: what holds for `account` and what decided
/// it (`local`, `machine`, `account` or `none`).
fn effective(authority: &Authority, account: Option<&str>) -> Value {
    let raw = authority.status();
    let status = super::machine_consent::for_account(raw.clone(), account);
    let mut out = Map::new();
    for (surface, source) in [("control", "controlSource"), ("screen", "screenSource")] {
        let granted = |status: &Value| {
            status.pointer(&format!("/consent/{surface}")).and_then(Value::as_str)
                == Some("granted")
        };
        let on = granted(&status);
        let source = if granted(&raw) && !on {
            // Granted for another account: none holds now.
            "none"
        } else {
            match raw.pointer(&format!("/consent/{source}")).and_then(Value::as_str) {
                Some(source) => source,
                // A file an older build wrote: what it holds is the person's own setting.
                None if on => "local",
                None => "none",
            }
        };
        out.insert(surface.into(), json!({"on": on, "source": source}));
    }
    Value::Object(out)
}

/// How long one viewer's repeated connects for one surface write a single `auto_allow` line.
pub const AUTO_ALLOW_LOG_MS: u64 = 60_000;

/// One viewer device's ask to share this machine (`_acpmux/consent_screen_auto`), as the device
/// hub names it.
#[derive(Clone, Debug, Default)]
pub struct Viewer {
    /// The hub's device id of the viewer.
    pub id: String,
    pub name: Option<String>,
    /// The hub user the viewer is signed in as, when the hub said.
    pub hub_user: Option<String>,
}

/// Whether the app here may skip its per-connect prompt for `viewer` on `surface` (`screen` or
/// `control`) at `now`: `{allowed, source, reason?}`. Allowed only when this machine is joined
/// (`account`), the viewer's hub user (when given) is that account, and the effective consent for
/// the surface is on, from the person's setting here, this machine's grant or the account policy.
/// An allowed answer logs `auto_allow`, once per viewer and surface in [`AUTO_ALLOW_LOG_MS`].
pub(crate) fn screen_auto(
    authority: &Authority,
    account: Option<&str>,
    surface: &str,
    viewer: &Viewer,
    now: u64,
) -> Value {
    let refuse =
        |source: &str, reason: &str| json!({"allowed": false, "source": source, "reason": reason});
    let Some(account) = account else {
        return refuse("none", "not_joined");
    };
    if viewer.hub_user.as_deref().is_some_and(|user| user != account) {
        return refuse("none", "account");
    }
    let effective = effective(authority, Some(account));
    let on = effective.pointer(&format!("/{surface}/on")) == Some(&Value::Bool(true));
    let source = effective
        .pointer(&format!("/{surface}/source"))
        .and_then(Value::as_str)
        .unwrap_or("none")
        .to_owned();
    if !on || !matches!(source.as_str(), "local" | "machine" | "account") {
        return refuse(&source, "consent_off");
    }
    let id = bounded(&viewer.id);
    let recent = log_lines(authority.root(), MAX_LOG_LINES).iter().rev().any(|line| {
        line["event"] == "auto_allow"
            && line["surface"] == surface
            && line["viewer"].as_str() == Some(id.as_str())
            && line["at"].as_u64().is_some_and(|at| now.saturating_sub(at) < AUTO_ALLOW_LOG_MS)
    });
    if !recent
        && authority.prepare().is_ok()
        && let Ok(_lock) = lock_waiting(authority)
    {
        let mut line = Map::new();
        line.insert("at".into(), json!(now));
        line.insert("event".into(), json!("auto_allow"));
        line.insert("surface".into(), json!(surface));
        line.insert("viewer".into(), json!(id));
        put(&mut line, "name", viewer.name.as_deref());
        line.insert("source".into(), json!(source));
        let _ = append_log(authority.root(), Value::Object(line));
    }
    json!({"allowed": true, "source": source})
}

/// What `machine_consent_get` adds for `account`, this machine's account now: the grantors
/// pinned for it, the pending ask made for it, the last lines of the log, the account policy,
/// the effective consent and its sources, and this machine's own app key (`own`) with its words.
pub(crate) fn status_fields(
    authority: &Authority,
    account: Option<&str>,
    own: Option<&OwnGrantor>,
) -> Map<String, Value> {
    let mut fields = grantor_fields(authority, account);
    fields.insert("accountPolicy".into(), account_policy(authority.root(), account));
    fields.insert("effective".into(), effective(authority, account));
    let own = own.map(|own| {
        let mut json = own.json();
        if let Some(fields) = json.as_object_mut() {
            fields.insert("words".into(), json!(words(&own.public_key)));
        }
        json
    });
    fields.insert("ownGrantor".into(), own.unwrap_or(Value::Null));
    fields
}

fn grantor_fields(authority: &Authority, account: Option<&str>) -> Map<String, Value> {
    let root = authority.root();
    let grantors: Grantors = read_json(&root.join(GRANTORS));
    let pinned: Vec<Value> = grantors
        .grantors
        .iter()
        .filter(|pin| account == Some(pin.account.as_str()))
        .filter_map(|pin| {
            let key = pin.key()?;
            Some(json!({"id": pin.id, "name": pin.name, "fingerprint": fingerprint(&key),
                "words": words(&key), "pinnedAt": pin.pinned_at}))
        })
        .collect();
    let ask_json = |ask: &Ask| {
        json!({"id": ask.id, "name": ask.name, "from": ask.from, "at": ask.at,
            "words": ask.words})
    };
    let asks: Vec<Value> = read_asks(root)
        .iter()
        .filter(|ask| account == Some(ask.account.as_str()))
        .map(ask_json)
        .collect();
    let mut fields = Map::new();
    fields.insert("grantors".into(), Value::Array(pinned));
    // `grantorAsk` is the newest ask, as before; `grantorAsks` all of them, oldest first.
    fields.insert("grantorAsk".into(), asks.last().cloned().unwrap_or(Value::Null));
    fields.insert("grantorAsks".into(), Value::Array(asks));
    fields.insert("grantLog".into(), Value::Array(log_lines(root, STATUS_LOG_LINES)));
    fields
}

/// `acpmux host grantors list`: every pin, whichever account it was made for, and the ask.
pub(crate) fn list(authority: &Authority) -> Value {
    let root = authority.root();
    let grantors: Grantors = read_json(&root.join(GRANTORS));
    let pins: Vec<Value> = grantors
        .grantors
        .iter()
        .map(|pin| {
            let key = pin.key().unwrap_or_default();
            json!({"id": pin.id, "name": pin.name, "account": pin.account,
                "fingerprint": fingerprint(&key), "words": words(&key), "pinnedAt": pin.pinned_at})
        })
        .collect();
    json!({"grantors": pins, "grantorAsks": read_asks(root)})
}

/// The newest log lines about `grantor` (`by` it), at most [`STATUS_LOG_LINES`]: what the carrier
/// shows the asking Mac. Lines about other Macs, and every line when it names none, stay here.
fn grantor_lines(root: &Path, grantor: Option<&str>) -> Vec<Value> {
    let Some(grantor) = grantor else {
        return Vec::new();
    };
    let mut lines: Vec<Value> = log_lines(root, MAX_LOG_LINES.saturating_add(MAX_NOISY_LOG_LINES))
        .into_iter()
        .rev()
        .filter(|line| line["by"].as_str() == Some(grantor))
        .take(STATUS_LOG_LINES)
        .collect();
    lines.reverse();
    lines
}

/// The carrier's `status` answer for `target`, and whether `grantor` (the asking Mac's id) is
/// pinned here for this machine's account.
#[cfg_attr(not(feature = "hub-carrier"), allow(dead_code))] // the carrier's consent service
pub(crate) fn remote_status(
    authority: &Authority,
    target: &Target,
    grantor: Option<&str>,
) -> Value {
    let account = target.account.as_deref();
    let status = super::machine_consent::for_account(authority.status(), account);
    let consent = status.get("consent").cloned().unwrap_or(Value::Null);
    let granted = |surface: &str| consent.get(surface).and_then(Value::as_str) == Some("granted");
    let by = |field: &str| consent.get(field).cloned().unwrap_or(Value::Null);
    let grantors: Grantors = read_json(&authority.root().join(GRANTORS));
    let grantor_id_asked = grantor;
    let grantor = grantor.map(|id| {
        json!({"pinned": account.is_some_and(|account| grantors.pinned(id, account).is_some())})
    });
    json!({
        "ok": true,
        "machineId": target.machine_id,
        "nodeKey": target.node_key,
        "account": account,
        "host": target.name,
        "control": granted("control"),
        "screen": granted("screen"),
        "controlGrantedBy": by("controlGrantedBy"),
        "screenGrantedBy": by("screenGrantedBy"),
        "grantor": grantor,
        "grantLog": grantor_lines(authority.root(), grantor_id_asked),
        "ownGrantor": target.own_grantor.as_ref().map(OwnGrantor::json),
        "accountPolicy": account_policy(authority.root(), account),
        "effective": effective(authority, account),
    })
}

/// One carrier request (`{"op":"status","grantor"?}`, `{"op":"set","grant"}` or
/// `{"op":"policy"}`) from the machine the hub book lists as `from`, and its answer. `policy`
/// answers the account policy kept here, whole, which the asker verifies itself.
#[cfg_attr(not(feature = "hub-carrier"), allow(dead_code))] // the carrier's consent service
pub(crate) fn handle_request(
    authority: &Authority,
    target: &Target,
    from: Option<&str>,
    request: &[u8],
    now: u64,
) -> Value {
    let refuse = |reason: &str, error: &str| json!({"ok": false, "reason": reason, "error": error});
    if request.len() > MAX_REQUEST_BYTES {
        return refuse("request.too_large", "the request is larger than 8 KiB");
    }
    let Ok(request) = serde_json::from_slice::<Value>(request) else {
        return refuse("request.malformed", "the request is not JSON");
    };
    match request.get("op").and_then(Value::as_str) {
        Some("status") => {
            remote_status(authority, target, request.get("grantor").and_then(Value::as_str))
        }
        Some("set") => {
            let grant = request.get("grant").unwrap_or(&Value::Null);
            match apply(authority, grant, target, from, now) {
                Ok(_) => {
                    let grantor = grant.get("grantor").and_then(Value::as_str);
                    remote_status(authority, target, grantor)
                }
                Err(refusal) => refusal.answer(),
            }
        }
        Some("policy") => json!({
            "ok": true,
            "grant": policy_grant(authority.root(), target.account.as_deref()),
        }),
        _ => refuse("request.unknown", "the request names no op this machine serves"),
    }
}

/// The last `count` log lines, oldest first.
pub(crate) fn log_lines(root: &Path, count: usize) -> Vec<Value> {
    let text = read_text(&root.join(LOG));
    let lines: Vec<&str> = text.lines().filter(|line| !line.trim().is_empty()).collect();
    let skip = lines.len().saturating_sub(count);
    lines.into_iter().skip(skip).filter_map(|line| serde_json::from_str(line).ok()).collect()
}

fn append_log(root: &Path, line: Value) -> Result<()> {
    let path = root.join(LOG);
    let text = read_text(&path);
    let mut lines: Vec<String> =
        text.lines().filter(|line| !line.trim().is_empty()).map(str::to_owned).collect();
    lines.push(line.to_string());
    // Newest first, each kind up to its own cap: refusals and asks never evict the rest.
    let (mut noisy, mut other) = (0usize, 0usize);
    let mut kept: Vec<String> = Vec::new();
    for line in lines.into_iter().rev() {
        let event = serde_json::from_str::<Value>(&line)
            .ok()
            .and_then(|value| value.get("event").and_then(Value::as_str).map(str::to_owned));
        let (count, cap) = if matches!(event.as_deref(), Some("refused" | "ask")) {
            (&mut noisy, MAX_NOISY_LOG_LINES)
        } else {
            (&mut other, MAX_LOG_LINES)
        };
        if *count < cap {
            *count = count.saturating_add(1);
            kept.push(line);
        }
    }
    let mut out = String::new();
    for line in kept.into_iter().rev() {
        out.push_str(&line);
        out.push('\n');
    }
    crate::config::write_atomic(&path, out.as_bytes())
}

#[allow(clippy::too_many_arguments)]
fn log_refused(
    root: &Path,
    by: &str,
    name: Option<&str>,
    refusal: &Refusal,
    from: Option<&str>,
    account: Option<&str>,
    now: u64,
) {
    let mut line = event(now, "refused", by);
    put(&mut line, "name", name.filter(|n| !n.is_empty()));
    put(&mut line, "reason", Some(refusal.reason));
    put(&mut line, "from", from);
    put(&mut line, "account", account);
    let _ = append_log(root, Value::Object(line));
}

fn event(at: u64, event: &str, by: &str) -> Map<String, Value> {
    let mut line = Map::new();
    line.insert("at".into(), json!(at));
    line.insert("event".into(), json!(event));
    line.insert("by".into(), json!(bounded(by)));
    line
}

fn put(line: &mut Map<String, Value>, key: &str, value: Option<&str>) {
    if let Some(value) = value {
        line.insert(key.into(), json!(bounded(value)));
    }
}

/// A text a log line or ask keeps: at most 128 characters, no control characters.
fn bounded(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).take(128).collect()
}

/// The authority's lock, waiting up to about half a second for another change to finish.
pub(crate) fn lock_waiting(authority: &Authority) -> Result<HeldLock> {
    for _ in 0..25 {
        if let Ok(lock) = authority.lock() {
            return Ok(lock);
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    authority.lock()
}

fn read_text(path: &Path) -> String {
    use std::io::Read;
    let mut text = String::new();
    let read = crate::config::private_state_file(path)
        .is_ok_and(|mut file| file.read_to_string(&mut text).is_ok());
    if read { text } else { String::new() }
}

/// A file of the authority as `T`; missing or unreadable reads as none, which pins nothing.
fn read_json_opt<T: DeserializeOwned>(path: &Path) -> Option<T> {
    crate::config::private_state_file(path).ok().and_then(|file| serde_json::from_reader(file).ok())
}

fn read_json<T: DeserializeOwned + Default>(path: &Path) -> T {
    read_json_opt(path).unwrap_or_default()
}

fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    crate::config::write_atomic(path, &serde_json::to_vec(value)?)
}

fn remove(path: &Path) -> std::io::Result<()> {
    match crate::home_fs::remove_file(path) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

/// `mac-` and 16 lowercase hex digits.
fn valid_grantor(id: &str) -> bool {
    id.strip_prefix("mac-").is_some_and(|rest| {
        rest.len() == 16 && rest.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

/// Standard base64 of 32 bytes, as the hub writes a `daemonId`.
fn node_key_bytes(text: &str) -> bool {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(text).is_ok_and(|bytes| bytes.len() == 32)
}

/// Lowercase hex as bytes.
pub(crate) fn unhex(text: &str) -> Option<Vec<u8>> {
    let digit = |b: u8| match b {
        b'0'..=b'9' => Some(b.wrapping_sub(b'0')),
        b'a'..=b'f' => Some(b.wrapping_sub(b'a').wrapping_add(10)),
        _ => None,
    };
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(2) {
        return None;
    }
    bytes
        .chunks_exact(2)
        .map(|pair| match pair {
            [high, low] => Some(digit(*high)?.wrapping_mul(16) | digit(*low)?),
            _ => None,
        })
        .collect()
}

/// `acpmux machine grantors list|rm ID`: the account's pins, read or narrowed in place. No command
/// adds a pin: only the person in the cmux app here does.
pub(crate) fn run_grantors(cmd: super::command_host::GrantorsCmd, json_out: bool) -> Result<()> {
    use super::command_host::GrantorsCmd;
    let authority = super::cloud_join::authority()?;
    let value = match cmd {
        GrantorsCmd::List => list(&authority),
        GrantorsCmd::Rm { id } => {
            let account = super::cloud_join::machine_user_id();
            let now = crate::store::now_ms();
            trust(&authority, &id, false, account.as_deref(), now).map_err(|error| match error {
                TrustError::Invalid(message) => anyhow::anyhow!(message),
                TrustError::Store => anyhow::anyhow!("this machine's consent store is unavailable"),
            })?
        }
    };
    if json_out {
        super::output::print_json(&value);
        return Ok(());
    }
    if let Some(pins) = value.get("grantors").and_then(Value::as_array) {
        if pins.is_empty() {
            println!("no Mac may switch Control and Screen here");
        }
        for pin in pins {
            let text = |key: &str| pin.get(key).and_then(Value::as_str).unwrap_or_default();
            let words = pin.get("words").map(Value::to_string).unwrap_or_default();
            println!("{}  {}  {}  {words}", text("id"), text("name"), text("account"));
        }
        for ask in value.get("grantorAsks").and_then(Value::as_array).into_iter().flatten() {
            println!("pending ask (answer it in the cmux app here): {ask}");
        }
    } else {
        let unpinned = value.get("unpinned").and_then(Value::as_bool) == Some(true);
        println!("{}", if unpinned { "removed" } else { "no such Mac was trusted" });
    }
    Ok(())
}

#[cfg(test)]
#[path = "consent_grant_tests.rs"]
mod tests;
