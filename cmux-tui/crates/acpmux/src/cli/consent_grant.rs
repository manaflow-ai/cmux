//! Control and Screen consent the owner turns on or off for this machine from his own cmux app on
//! another machine (Leo, 2026-11-15: "yeah just change it pls"), instead of a click on this one.
//!
//! Trust design:
//! - The signer is the owner Mac's approver key (`hub/mac_approvers.rs`): P-256 in that Mac's
//!   Secure Enclave, used only by the signed cmux app, which signs a grant only after the person's
//!   own gesture and Touch ID or password. An agent, a shell or the daemon on that Mac cannot make
//!   it sign.
//! - This machine checks a grant only against keys it pinned itself, in its account-wide consent
//!   authority (`grantors.json` beside `consent.json`, private state). A key is pinned only by the
//!   person in the cmux app here (`_acpmux/consent_grantor_trust` on the person's local
//!   connection), from the ask the first unpinned grant left (`grantor-ask.json`), once they
//!   matched its four words with the ones the owner Mac shows for its own key. No RPC from
//!   elsewhere, no CLI, no platform answer and no carrier message pins a key: that is the one
//!   person step per machine.
//! - The platform, the relay, the machine credential and the carrier only carry grants. They hold
//!   no pinned key, so they can drop, delay or replay one: a replay is refused (the last accepted
//!   `issuedAt` per grantor), a delay is bounded (a grant message lives at most 5 minutes), and a
//!   key they put in an ask fails the person's word check.
//! - A grant names one machine (its platform machine id and its node key, the hub `daemonId`), the
//!   account (hub user id) both machines are joined as, and a change for control and for screen.
//!   What it turns on lasts until it is turned off: by a signed off, by the local Off, or by
//!   unpinning the key here. Once this machine is joined as another account, what was granted for
//!   the old one reads as not given ([`super::machine_consent::for_account`]).
//! - Every outcome, accepted or refused, and every local change is a line of `grants.jsonl`.
//!
//! What this does not change: a process running as this machine's OS user (ssh as that user too)
//! can already write `consent.json`; this adds no new path for it. The platform supplies the list
//! of machines a switch shows, so it can confuse which of the person's own pinned machines a row
//! names; it cannot reach a machine that did not pin the key.

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
/// The grant log keeps this many lines, newest last.
pub const MAX_LOG_LINES: usize = 200;
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

const GRANTORS: &str = "grantors.json";
const ASK: &str = "grantor-ask.json";
const LOG: &str = "grants.jsonl";

/// What a grant does to one surface.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Change {
    On,
    Off,
    Keep,
}

impl Change {
    pub fn word(self) -> &'static str {
        match self {
            Change::On => "on",
            Change::Off => "off",
            Change::Keep => "keep",
        }
    }

    fn parse(word: &str) -> Option<Self> {
        match word {
            "on" => Some(Change::On),
            "off" => Some(Change::Off),
            "keep" => Some(Change::Keep),
            _ => None,
        }
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
    return DOMAIN.as_bytes().to_vec(); // red stub
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
    if !node_key_bytes(&node_key) {
        return Err(bad("nodeKey"));
    }
    let (control, screen) = (change("control")?, change("screen")?);
    if control == Change::Keep && screen == Change::Keep {
        return Err(bad("control and screen are both keep"));
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
    return Ok(()); // red stub
    let Some(account) = target.account.as_deref() else {
        return Err(Refusal::new(NOT_JOINED, "this machine is not joined to an account"));
    };
    if grant.account != account {
        return Err(Refusal::new(ACCOUNT, "the grant is for another account than this machine's"));
    }
    if target.machine_id.as_deref() != Some(grant.machine_id.as_str())
        || target.node_key.as_deref() != Some(grant.node_key.as_str())
    {
        return Err(Refusal::new(TARGET, "the grant names another machine"));
    }
    let lifetime_ok = grant
        .expires_at
        .checked_sub(grant.issued_at)
        .is_some_and(|lifetime| lifetime <= MAX_LIFETIME_MS);
    if grant.expires_at <= now || !lifetime_ok || grant.issued_at > now.saturating_add(MAX_AHEAD_MS)
    {
        return Err(Refusal::new(EXPIRED, "the grant expired or is not valid yet"));
    }
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
    if grantors.seq.get(&grant.grantor).is_some_and(|last| grant.issued_at <= *last) {
        return Err(Refusal::new(REPLAYED, "the grant was already used or is older than one used"));
    }
    Ok(())
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

fn signed_by(grant: &Grant, key: &[u8]) -> bool {
    ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, key)
        .verify(&grant.message(), &grant.signature)
        .is_ok()
}

/// Applies a grant under the authority's lock: verify, then the grantor's counter, then
/// `consent.json` with each changed surface's provenance, then the log. A refusal is logged too,
/// and an unpinned grant whose key checks out leaves the one pending ask. `from` names the
/// machine that carried it (a host the hub lists).
pub(crate) fn apply(
    authority: &Authority,
    value: &Value,
    target: &Target,
    from: Option<&str>,
    now: u64,
) -> Result<super::cloud_join::Consent, Refusal> {
    return Err(Refusal::new(STORE, "red stub"));
    let store = || Refusal::new(STORE, "this machine's consent store is unavailable");
    authority.prepare().map_err(|_| store())?;
    let _lock = lock_waiting(authority)
        .map_err(|_| Refusal::new(BUSY, "a consent change is in progress here; try again"))?;
    let root = authority.root();
    let grant = match parse(value) {
        Ok(grant) => grant,
        Err(refusal) => {
            let by = value.get("grantor").and_then(Value::as_str).filter(|g| valid_grantor(g));
            log_refused(root, by.unwrap_or("unknown"), None, &refusal, from, None, now);
            return Err(refusal);
        }
    };
    let mut grantors: Grantors = read_json(&root.join(GRANTORS));
    if let Err(refusal) = verify(&grant, target, &grantors, now) {
        if refusal.reason == UNPINNED
            && let Some(key) = ask_key(&grant)
        {
            let ask = Ask {
                id: grant.grantor.clone(),
                public_key: hex(&key),
                name: grant.name.clone(),
                account: grant.account.clone(),
                from: from.map(bounded),
                at: now,
                words: words(&key).iter().map(|w| (*w).to_owned()).collect(),
            };
            if write_json(&root.join(ASK), &ask).is_ok() {
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
    grantors.seq.insert(grant.grantor.clone(), grant.issued_at);
    write_json(&root.join(GRANTORS), &grantors).map_err(|_| store())?;
    let mut consent = authority.consent();
    let by = GrantedBy { grantor: grant.grantor.clone(), account: grant.account.clone(), at: now };
    let mut changed = Vec::new();
    for (surface, change, state, granted_by) in [
        ("control", grant.control, &mut consent.control, &mut consent.control_granted_by),
        ("screen", grant.screen, &mut consent.screen, &mut consent.screen_granted_by),
    ] {
        match change {
            Change::On => {
                *state = ConsentState::Granted;
                *granted_by = Some(by.clone());
                changed.push((surface, "grant"));
            }
            Change::Off => {
                *state = ConsentState::None;
                *granted_by = None;
                changed.push((surface, "revoke"));
            }
            Change::Keep => {}
        }
    }
    if grant.control == Change::On || grant.screen == Change::On {
        consent.granted_at = Some(now.to_string());
    }
    let bytes = serde_json::to_vec(&consent).map_err(|_| store())?;
    crate::config::write_atomic(&root.join("consent.json"), &bytes).map_err(|_| store())?;
    for (surface, what) in changed {
        let mut line = event(now, what, &grant.grantor);
        put(&mut line, "name", Some(name.as_str()).filter(|n| !n.is_empty()));
        put(&mut line, "surface", Some(surface));
        put(&mut line, "from", from);
        put(&mut line, "account", Some(grant.account.as_str()));
        let _ = append_log(root, Value::Object(line));
    }
    Ok(consent)
}

/// Logs a local consent change (`machine_consent_set`), `by: "local"`. The caller holds the lock.
pub(crate) fn log_local(authority: &Authority, surface: &str, granted: bool) -> Result<()> {
    return Ok(()); // red stub
    let mut line = event(crate::store::now_ms(), if granted { "grant" } else { "revoke" }, "local");
    put(&mut line, "surface", Some(surface));
    append_log(authority.root(), Value::Object(line))
}

/// Why a trust change was not made.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum TrustError {
    /// The request does not match a pending ask, or no room is left: the caller's to fix.
    Invalid(String),
    Store,
}

/// `_acpmux/consent_grantor_trust {id, trusted}`: trusted pins the pending ask's key when its id
/// is `id` and it was made for `account`, this machine's account now; not trusted unpins `id`
/// and dismisses its ask. The caller proved the person on a local connection.
pub(crate) fn trust(
    authority: &Authority,
    id: &str,
    trusted: bool,
    account: Option<&str>,
    now: u64,
) -> Result<Value, TrustError> {
    return Err(TrustError::Store); // red stub
    authority.prepare().map_err(|_| TrustError::Store)?;
    let _lock = lock_waiting(authority).map_err(|_| TrustError::Store)?;
    let root = authority.root();
    let ask: Option<Ask> = read_json_opt(&root.join(ASK));
    let mut grantors: Grantors = read_json(&root.join(GRANTORS));
    if trusted {
        let ask = ask
            .filter(|ask| ask.id == id && account == Some(ask.account.as_str()))
            .ok_or_else(|| {
                TrustError::Invalid(
                    "no pending ask from that Mac for the account this machine is joined as".into(),
                )
            })?;
        grantors.grantors.retain(|pin| pin.id != ask.id);
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
        remove(&root.join(ASK)).map_err(|_| TrustError::Store)?;
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
        let _ = append_log(root, Value::Object(event(now, "unpinned", id)));
    }
    let dismissed = ask.is_some_and(|ask| ask.id == id);
    if dismissed {
        remove(&root.join(ASK)).map_err(|_| TrustError::Store)?;
    }
    Ok(json!({"unpinned": unpinned, "dismissed": dismissed}))
}

/// What `machine_consent_get` adds for `account`, this machine's account now: the grantors
/// pinned for it, the pending ask made for it, and the last lines of the log.
pub(crate) fn status_fields(authority: &Authority, account: Option<&str>) -> Map<String, Value> {
    return Map::new(); // red stub
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
    let ask = read_json_opt::<Ask>(&root.join(ASK))
        .filter(|ask| account == Some(ask.account.as_str()))
        .map(|ask| {
            json!({"id": ask.id, "name": ask.name, "from": ask.from, "at": ask.at,
            "words": ask.words})
        });
    let mut fields = Map::new();
    fields.insert("grantors".into(), Value::Array(pinned));
    fields.insert("grantorAsk".into(), ask.unwrap_or(Value::Null));
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
    json!({"grantors": pins, "grantorAsk": read_json_opt::<Ask>(&root.join(ASK))})
}

/// The carrier's `status` answer for `target`, and whether `grantor` (the asking Mac's id) is
/// pinned here for this machine's account.
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
        "grantLog": log_lines(authority.root(), STATUS_LOG_LINES),
    })
}

/// One carrier request (`{"op":"status","grantor"?}` or `{"op":"set","grant"}`) from the machine
/// the hub book lists as `from`, and its answer.
pub(crate) fn handle_request(
    authority: &Authority,
    target: &Target,
    from: Option<&str>,
    request: &[u8],
    now: u64,
) -> Value {
    return json!({"ok": false}); // red stub
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
    let skip = lines.len().saturating_sub(MAX_LOG_LINES);
    let mut out = String::new();
    for line in lines.into_iter().skip(skip) {
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
fn lock_waiting(authority: &Authority) -> Result<HeldLock> {
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
    match crate::config::private_state_file(path) {
        Ok(mut file) if file.read_to_string(&mut text).is_ok() => text,
        _ => String::new(),
    }
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
    match std::fs::remove_file(path) {
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
        if let Some(ask) = value.get("grantorAsk").filter(|ask| !ask.is_null()) {
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
