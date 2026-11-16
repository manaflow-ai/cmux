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
//!   authority (`grantors.json` beside `consent.json`, private state). It pins keys with no prompt
//!   only during its own enrollment, a step the person takes here (a sign-in's new join, a join
//!   line, or Refresh trusted Macs in the app): its own app's key, and the keys its listed peers of
//!   the same account report, for [`ENROLL_WINDOW_MS`] after that step ([`open_window`],
//!   [`pin_enrolled`]). Any other key is pinned only by the person in the cmux app here
//!   (`_acpmux/consent_grantor_trust`), from the ask the first grant it signed left
//!   (`grantor-ask.json`), once they matched its four words with the ones the owner Mac shows.
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
//! - Every outcome, accepted or refused, every pin and every local change is a line of
//!   `grants.jsonl`.
//!
//! What this does not change, and what it leaves: a process running as this machine's OS user
//! (ssh as that user too) can already write `consent.json`; this adds no new path for it. Pinning
//! without a prompt trusts the platform only at this machine's own enrollment, which already
//! trusts it (it serves the join and names the account): what the platform names then is pinned.
//! After the window closes it cannot add a key; a Mac that signs in later needs a person step here
//! (Refresh trusted Macs, or the four-word ask). The platform supplies the list of machines a
//! switch shows, so it can confuse which of the person's own pinned machines a row names; it
//! cannot reach a machine that did not pin the key.

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

/// An account-wide grant `_acpmux/consent_account_set` was given is not one this machine's own
/// app key signed.
pub const NOT_OWN: &str = "grant.not_own";

/// The `machineId` and `nodeKey` of an account-wide grant.
pub const ANY: &str = "*";
/// How long after this machine's enrollment step its peers' reported keys are pinned, in ms.
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
    /// Per-machine grants only.
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

    /// Whether this grant is for every machine of the account (`*`).
    pub fn account_wide(&self) -> bool {
        self.machine_id == ANY
    }

    /// The change for `surface` (`control` or `screen`).
    fn change(&self, surface: &str) -> Change {
        if surface == "control" { self.control } else { self.screen }
    }

    /// The counter this grant is checked against: one per grantor for per-machine grants and one
    /// for its account-wide grants, so neither kind holds the other back.
    fn seq_key(&self) -> String {
        if self.account_wide() { format!("{}/{ANY}", self.grantor) } else { self.grantor.clone() }
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
    if account_wide && (control == Change::Default || screen == Change::Default) {
        return Err(bad("default is for a per-machine grant"));
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
    grantors.seq.insert(grant.seq_key(), grant.issued_at);
    write_json(&root.join(GRANTORS), &grantors).map_err(|_| store())?;
    if grant.account_wide() {
        // The newest account policy for this account is kept whole, signature included, so this
        // machine can hand it on to a peer that enrolls later (`op: "policy"`).
        let newer = read_policy(root)
            .filter(|(kept, _)| kept.account == grant.account)
            .is_none_or(|(kept, _)| grant.issued_at > kept.issued_at);
        if newer {
            write_json(&root.join(POLICY), &json!({"grant": value, "at": now}))
                .map_err(|_| store())?;
        }
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
    let mut consent = authority.consent();
    consent.control_local = local_of(&consent, "control");
    consent.screen_local = local_of(&consent, "screen");
    recompute(root, &mut consent, Some(&grant.account));
    if grant.control == Change::On || grant.screen == Change::On {
        consent.granted_at = Some(now.to_string());
    }
    let bytes = serde_json::to_vec(&consent).map_err(|_| store())?;
    crate::config::write_atomic(&root.join("consent.json"), &bytes).map_err(|_| store())?;
    for surface in ["control", "screen"] {
        let what = match grant.change(surface) {
            Change::On => "grant",
            Change::Off => "revoke",
            Change::Default => "default",
            Change::Keep => continue,
        };
        let mut line = event(now, what, &grant.grantor);
        put(&mut line, "name", Some(name.as_str()).filter(|n| !n.is_empty()));
        put(&mut line, "surface", Some(surface));
        put(&mut line, "scope", Some(if grant.account_wide() { "account" } else { "machine" }));
        put(&mut line, "from", from);
        put(&mut line, "account", Some(grant.account.as_str()));
        let _ = append_log(root, Value::Object(line));
    }
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
/// as the value itself: granted there was the person's own On.
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
    (matches!(state, ConsentState::Granted) && by.is_none()).then_some(true)
}

/// The account policy kept here and when it was applied, parsed.
fn read_policy(root: &Path) -> Option<(Grant, u64)> {
    let kept: Value = read_json_opt(&root.join(POLICY))?;
    let at = kept.get("at").and_then(Value::as_u64).unwrap_or_default();
    parse(kept.get("grant")?).ok().map(|grant| (grant, at))
}

/// The account policy kept here for `account`, whole, as a peer verifies it.
pub(crate) fn policy_grant(root: &Path, account: Option<&str>) -> Option<Value> {
    return None; // red stub
    let kept: Value = read_json_opt(&root.join(POLICY))?;
    let grant = kept.get("grant")?;
    let parsed = parse(grant).ok()?;
    (account == Some(parsed.account.as_str())).then(|| grant.clone())
}

/// When the account policy kept here for `account` was issued.
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
    return; // red stub
    let mine = |grant_account: &str| account.is_none_or(|account| account == grant_account);
    let records: MachineGrants = read_json(&root.join(MACHINE_GRANTS));
    let policy = read_policy(root).filter(|(grant, _)| mine(&grant.account));
    for surface in ["control", "screen"] {
        let local = if surface == "control" { consent.control_local } else { consent.screen_local };
        let record = if surface == "control" { &records.control } else { &records.screen };
        let record = record.clone().filter(|record| mine(&record.account));
        let account_record = policy.as_ref().and_then(|(grant, at)| {
            grant.change(surface).value().map(|on| Record {
                on,
                issued_at: grant.issued_at,
                grantor: grant.grantor.clone(),
                account: grant.account.clone(),
                at: *at,
            })
        });
        let signed = match (record, account_record) {
            (Some(record), Some(policy)) if policy.issued_at > record.issued_at => {
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

/// Opens this machine's enrollment window at `now`: for [`ENROLL_WINDOW_MS`] its own app key and
/// the keys its peers report are pinned with no prompt ([`pin_enrolled`]). Only a step the
/// person takes here opens it: a sign-in's new join, a join line, Refresh trusted Macs.
pub(crate) fn open_window(authority: &Authority, now: u64) -> Result<()> {
    authority.prepare()?;
    let _lock = lock_waiting(authority)?;
    let until = now.saturating_add(ENROLL_WINDOW_MS);
    write_json(&authority.root().join(WINDOW), &json!({"opened": now, "until": until}))
}

/// Whether the enrollment window is open at `now`.
pub(crate) fn window_open(authority: &Authority, now: u64) -> bool {
    read_json_opt::<Value>(&authority.root().join(WINDOW))
        .and_then(|window| Some((window.get("opened")?.as_u64()?, window.get("until")?.as_u64()?)))
        .is_some_and(|(opened, until)| opened <= now && now <= until)
}

/// Pins `key` (named `name`) for `account` with no prompt, while the enrollment window is open:
/// this machine's own app key, or one a listed peer of the account reported. True when it was
/// not pinned before. Logs `pinned` with `via: "enroll"` and drops an ask for the same key.
pub(crate) fn pin_enrolled(
    authority: &Authority,
    key: &[u8],
    name: &str,
    account: &str,
    now: u64,
) -> Result<bool, TrustError> {
    return Err(TrustError::Store); // red stub
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
    let mut grantors: Grantors = read_json(&root.join(GRANTORS));
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
    if read_json_opt::<Ask>(&root.join(ASK)).is_some_and(|ask| ask.id == id) {
        remove(&root.join(ASK)).map_err(|_| TrustError::Store)?;
    }
    let mut line = event(now, "pinned", &id);
    put(&mut line, "via", Some("enroll"));
    put(&mut line, "name", Some(name.as_str()).filter(|n| !n.is_empty()));
    put(&mut line, "account", Some(account));
    let _ = append_log(root, Value::Object(line));
    Ok(true)
}

/// The account-wide grant `_acpmux/consent_account_set` takes: one this machine's own app key
/// (`own`) signed, for every machine (`*`). Anything else is refused before it is applied or
/// handed to a peer.
pub fn own_account_grant(value: &Value, own: Option<&OwnGrantor>) -> Result<Grant, Refusal> {
    return parse(value); // red stub
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

/// The account policy kept here for `account`, as a status shows it:
/// `{grantor, issuedAt, control, screen}`, or null.
fn account_policy(root: &Path, account: Option<&str>) -> Value {
    read_policy(root).filter(|(grant, _)| account == Some(grant.account.as_str())).map_or(
        Value::Null,
        |(grant, _)| {
            json!({"grantor": grant.grantor, "issuedAt": grant.issued_at,
                "control": grant.control.word(), "screen": grant.screen.word()})
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
        "ownGrantor": target.own_grantor.as_ref().map(OwnGrantor::json),
        "accountPolicy": account_policy(authority.root(), account),
        "effective": effective(authority, account),
    })
}

/// One carrier request (`{"op":"status","grantor"?}`, `{"op":"set","grant"}` or
/// `{"op":"policy"}`) from the machine the hub book lists as `from`, and its answer. `policy`
/// answers the account policy kept here, whole, which the asker verifies itself.
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
