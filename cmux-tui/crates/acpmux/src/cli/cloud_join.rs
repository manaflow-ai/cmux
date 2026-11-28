//! Cloud machine onboarding. The join secret is read from stdin and is never
//! placed in argv, the environment, a URL, or a diagnostic message.

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::PathBuf;

mod enroll;
pub(crate) use crate::host_fingerprint;
mod leave;
mod recovery;
mod self_capabilities;
mod sent_credential;
mod to_revoke;

pub(crate) use enroll::{
    EnrollOutcome, EnrollRequest, JOINED_BY_SIGN_IN, LeaveOutcome, enroll_self,
    finish_leave_at_start, leave_if_auto, leave_pending, mint_join_token, record_leave_intent,
    relay_may_start,
};
pub(crate) use self_capabilities::{
    state_after_leave as state_capabilities_after_leave,
    state_at_start as state_capabilities_at_start,
    state_on_reconnect as state_capabilities_on_reconnect,
};

// The join record and the consent gate live in `crate::machine_record`, which lower modules
// read; these keep their `cli::cloud_join` paths.
pub(crate) use crate::machine_record::authority;
#[cfg(test)]
use crate::machine_record::home_copy_state;
pub(super) use crate::machine_record::load_at;
pub use crate::machine_record::{
    CONSENT_REQUIRED, Consent, ConsentState, GrantedBy, MachineCredential, SIGNED_IN_MACHINES,
    require_consent, require_joined_consent, signed_in_machines_granted,
};
use crate::machine_record::{
    CREDENTIAL_FILE, CopyState, consent_home, copied_here, copy_state, load, other_box,
    settle_evidence, state_dir,
};
pub(crate) use crate::machine_record::{
    HeldLock, consent_status, is_consent_surface, machine_credential, machine_user_id,
    node_key_copied_at, record_consent_refusal, safe_id,
};

pub const CAPABILITY: &str = "machine.join.stdin.v1";
/// The hub a join with no `--hub` uses: cmux-platform's production origin
/// (Leo, 2026-11-04: "If I tell you to do something, don't stick it into
/// dev. Put it into prod."). `--hub` still names another one.
pub const DEFAULT_HUB: &str = cmux_cloud_client::backend::Backend::Production.platform();
const MAX_TOKEN_BYTES: usize = 512;

/// The capability that says this machine's acpmux runs the vault's egress proxy: the hub then
/// gives it proxy entries' values (`GET /v1/vault/machine`), never otherwise.
pub(crate) const VAULT_PROXY_CAPABILITY: &str = "vault.proxy.v1";

/// Whether this acpmux runs the vault's egress proxy. Every build carries it (`vault::egress`,
/// started on the first spawn that has a proxy entry, for the daemon's life), with no switch
/// that turns it off, so this is decided by the build: true.
const RUNS_EGRESS_PROXY: bool = true;

/// The list a redeem or a rotate sends, always (an empty list too: the hub reads a missing one
/// as a machine joined before it took the list).
fn capabilities_for(egress_proxy: bool) -> Vec<String> {
    if egress_proxy { vec![VAULT_PROXY_CAPABILITY.to_owned()] } else { Vec::new() }
}

/// This acpmux's list ([`capabilities_for`] with [`RUNS_EGRESS_PROXY`]).
fn machine_capabilities() -> Vec<String> {
    capabilities_for(RUNS_EGRESS_PROXY)
}

/// Where a join says what it did: printed for a person (`Text`), as JSON, or nowhere
/// (`Quiet`, the daemon's sign-in enroll, which answers its caller instead).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Report {
    Text,
    Json,
    Quiet,
}

impl Report {
    fn from_json(json_out: bool) -> Self {
        if json_out { Self::Json } else { Self::Text }
    }
}

/// What `host join --status` says to a copied box.
pub const CLONED_HINT: &str = "this machine's acpmux state was copied from another machine; its credential stays with that machine. Paste a new join line here to join this one.";

/// What the start-of-daemon clone check found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CloneCheck {
    NotJoined,
    /// No fingerprint here (no OS identity): nothing to compare.
    Unknown,
    Same,
    /// An older record with no fingerprint takes this box's.
    Adopted,
    /// Found now: marked cloned and given a fresh node key.
    Cloned,
    AlreadyCloned,
}

/// The non-secret part of a joined machine identity. The bearer credential is
/// intentionally absent so callers cannot accidentally serialize it.
#[derive(Debug, Clone, Serialize)]
pub(crate) struct MachineIdentity {
    pub machine_id: String,
    pub team_id: String,
    pub name: String,
    pub hub_origin: String,
    pub revoked: bool,
}

impl MachineIdentity {
    /// Copy only the non-secret fields used by local capability reporting.
    pub(crate) fn from_record(record: &MachineCredential) -> Self {
        Self {
            machine_id: record.machine_id.clone(),
            team_id: record.team_id.clone(),
            name: record.name.clone(),
            hub_origin: record.hub_origin.clone(),
            revoked: record.revoked,
        }
    }
}

fn credential_path() -> PathBuf {
    state_dir().join(CREDENTIAL_FILE)
}

pub fn parse_token_text(text: &str) -> Result<String> {
    let token = text.trim();
    if token.is_empty() {
        return Err(anyhow!("join token is empty"));
    }
    if !token.starts_with("cmj_")
        || token.len() <= 4
        || token.len() > MAX_TOKEN_BYTES
        || token.bytes().skip(4).any(|b| !(b.is_ascii_alphanumeric() || b == b'_' || b == b'-'))
    {
        return Err(anyhow!("join token is malformed"));
    }
    Ok(token.to_owned())
}

fn origin(value: Option<String>) -> Result<String> {
    let value = value
        .or_else(cmux_cloud_client::backend::platform_origin_env)
        .unwrap_or_else(|| DEFAULT_HUB.to_owned());
    let parsed =
        reqwest::Url::parse(value.trim()).map_err(|_| anyhow!("hub origin is malformed"))?;
    let loopback = matches!(parsed.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    anyhow::ensure!(
        parsed.scheme() == "https" || (parsed.scheme() == "http" && loopback),
        "hub origin must use https"
    );
    anyhow::ensure!(
        parsed.path() == "/"
            && parsed.username().is_empty()
            && parsed.password().is_none()
            && parsed.query().is_none()
            && parsed.fragment().is_none(),
        "hub origin must contain only scheme, host and port"
    );
    let origin = parsed.origin().ascii_serialization();
    // A hub the person or the app named (a preview or self-hosted platform): a host they name.
    cmux_egress::allow_named(&origin);
    Ok(origin)
}

fn local_name(name: Option<String>) -> String {
    name.unwrap_or_else(crate::pairing::host_label)
}

fn save(record: &MachineCredential) -> Result<()> {
    save_at(&state_dir(), record)
}

fn save_at(home: &std::path::Path, record: &MachineCredential) -> Result<()> {
    crate::config::private_state_dir(home)?;
    recovery::write_durable(&home.join(CREDENTIAL_FILE), &serde_json::to_vec_pretty(record)?, true)
}

/// At daemon start, before the WireGuard transport and the mesh relay: a record joined on
/// another box is marked `cloned` and this box gets a fresh `node.wg.key`, so it never answers
/// with the original's credential or key. The hub is not called: the original box's credential
/// stays as it is. An older record with no fingerprint adopts this box's.
pub(crate) fn settle_clone_at_start() -> Result<CloneCheck> {
    settle_clone_at_start_in(&state_dir())
}

/// [`settle_clone_at_start`] in acpmux home `home`. Every act on the node key is taken under
/// the join lock, and each replacement is a compare-and-replace
/// (`mesh_node_key::replace_copied_at`): a `host join` that ran after the evidence was read
/// replaced the copied key with a registered one, which stays.
fn settle_clone_at_start_in(home: &std::path::Path) -> Result<CloneCheck> {
    // Every piece of evidence first (a pending join begun on another box, with no record yet,
    // included): a copy it shows is recorded, then replaced below.
    let copied = node_key_copied_at(home);
    if !copied && load_at(home)?.is_none() {
        return Ok(CloneCheck::NotJoined);
    }
    #[cfg(test)]
    hooks::run();
    // A `host join` or `machine leave` may hold the lock for a moment: wait a bounded while
    // rather than skip the check (the caller keeps a still-unsettled copy off WireGuard).
    crate::config::private_state_dir(home)?;
    let mut tries = 0;
    let _lock = loop {
        match join_lock_in(home) {
            Ok(lock) => break lock,
            Err(_) if tries < 50 => {
                tries += 1;
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            Err(e) => return Err(e),
        }
    };
    // A node key recorded as copied from another machine (`mesh_node_key::record_copied_key`)
    // is replaced once nothing depends on it, joined or not (a leave may have removed the
    // record that showed the copy). Refused while the link adopted it: the caller keeps it off
    // WireGuard.
    // A refusal a cmux link wrote and stopped before it recorded the key: finished first.
    crate::cli::mesh_node_key::finish_link_refusals(home)?;
    crate::cli::mesh_node_key::replace_copied_at(home)?;
    settle_clone_at(home, host_fingerprint::current().as_deref())
}

/// A test hook in [`settle_clone_at_start_in`]: what runs after its evidence is read and
/// before it takes the join lock (a concurrent `host join`, in the race test).
#[cfg(test)]
pub(super) mod hooks {
    use std::cell::RefCell;

    thread_local! {
        pub(super) static AFTER_EVIDENCE: RefCell<Option<Box<dyn FnOnce()>>> =
            const { RefCell::new(None) };
    }

    pub(super) fn run() {
        if let Some(hook) = AFTER_EVIDENCE.with(|hook| hook.borrow_mut().take()) {
            hook();
        }
    }
}

/// Whether this home's record was joined on another box (marked or not yet marked).
pub(crate) fn copied_from_another_box() -> bool {
    copied_from_another_box_at(&state_dir())
}

/// Whether the record in acpmux home `home` was joined on another box (marked or not yet
/// marked): the clone check of every caller that knows which home it serves (the hub carrier,
/// the cmux link through `mesh_node_key::home_copied`), never this process's environment.
pub(crate) fn copied_from_another_box_at(home: &std::path::Path) -> bool {
    copied_at(home, host_fingerprint::current().as_deref())
}

/// What the cmux link's Cloud tunnel (cmux `carrier/tunnel_keeper.rs`) needs of this box's join:
/// the machine, its team, its name and the platform origin it joined through. Never the `cmm_`
/// credential: the tunnel attaches with the signed-in person's token.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JoinedDevice {
    pub machine_id: String,
    pub team_id: String,
    pub name: String,
    pub hub_origin: String,
}

/// This box's join in acpmux home `home`, when it is one the tunnel may run for: a live record
/// (not revoked, not a copy of another box's, its node key not a copied one) of a `machine_` id,
/// with no sign-out leave pending and no queued revoke of its own. None otherwise: the tunnel
/// stops then. A queued revoke of an earlier join does not stop it (`to_revoke::names`): the
/// sign-in that cleared that sign-out's leave mark enrolled this join, and the old revoke is asked
/// again at each start and sign-in, as the daemon's own start already reads it
/// (`finish_leave_at_start`: no mark is `signedIn`). On a Mac that signs in and out often, one
/// such revoke the hub never took kept the tunnel off for every join after it.
pub fn joined_device_at(home: &std::path::Path) -> Option<JoinedDevice> {
    let record = active_join_at(home)?;
    let hub_origin = origin(Some(record.hub_origin)).ok()?;
    Some(JoinedDevice {
        machine_id: record.machine_id,
        team_id: record.team_id,
        name: record.name,
        hub_origin,
    })
}

/// Owner of the active join in the specified authority's namespace.
pub(crate) fn browser_app_owner(hub: &str) -> Option<(String, String)> {
    let record = active_join_at(&state_dir())?;
    let joined_origin = origin(Some(record.hub_origin)).ok()?;
    if joined_origin != hub {
        return None;
    }
    Some((record.team_id, safe_id(&record.user_id?)?))
}

fn active_join_at(home: &std::path::Path) -> Option<MachineCredential> {
    let record = load_at(home).ok().flatten()?;
    let current = host_fingerprint::current();
    let left = std::fs::symlink_metadata(home.join(enroll::LEAVE_FILE)).is_ok()
        || to_revoke::names(home, &record);
    if record.revoked
        || record.cloned
        || left
        || !record.machine_id.starts_with("machine_")
        || record.team_id.is_empty()
        || copied_here(home, &record, current.as_deref())
        || node_key_copied_at(home)
    {
        return None;
    }
    Some(record)
}

/// This box's node key as its hub knows it (`wgPublicKey`, the hub's `daemonId`), for a join
/// [`joined_device_at`] counts as live: the route another machine of the account dials this one
/// by (`--via-machine KEY`). A cmux Remote invitation carries it (`via_machine`), so redeeming one
/// elsewhere needs no key passed by hand. None for a box that is not joined.
pub fn joined_node_key_at(home: &std::path::Path) -> Option<String> {
    joined_device_at(home)?;
    let key = load_at(home).ok().flatten()?.wg_public_key;
    use base64::Engine;
    base64::engine::general_purpose::STANDARD
        .decode(&key)
        .is_ok_and(|bytes| bytes.len() == 32)
        .then_some(key)
}

/// [`copied_from_another_box_at`], as the box whose fingerprint is `current`. A record that
/// cannot be read counts as no join (the daemon's own check reports it).
///
/// So is a home whose node key is still one recorded as copied from another machine
/// (`mesh_node_key::serves_copied_key`), with or without a record: a `machine leave` removes
/// the record, never that evidence.
fn copied_at(home: &std::path::Path, current: Option<&str>) -> bool {
    let record = load_at(home).ok().flatten();
    settle_evidence(home, record.as_ref(), current) != CopyState::Own
        || crate::cli::mesh_node_key::serves_copied_key(home)
}

/// [`settle_clone_at_start`] in `home`, as the box whose fingerprint is `current`. The caller
/// holds the join lock.
pub(crate) fn settle_clone_at(home: &std::path::Path, current: Option<&str>) -> Result<CloneCheck> {
    let Some(mut record) = load_at(home)? else { return Ok(CloneCheck::NotJoined) };
    match copy_state(home, &record, current) {
        CopyState::Unsettled => {
            use crate::cli::mesh_node_key::{
                public_key_at, record_copied_public_key, replace_at_if,
            };
            // Recorded before anything else: a failed replacement (the link adopted the key)
            // or a later leave never leaves the copy's key unmarked.
            let copied = public_key_at(home);
            if let Some(copied) = &copied {
                record_copied_public_key(home, copied)?;
            }
            // The mark before the key: a reader that sees the record unsettled after it read
            // the key read the copy's key, never the fresh one (`settle_evidence`). A start cut
            // short before the key is replaced finds the recorded key, and replaces it.
            record.cloned = true;
            record.cloned_on = current.map(str::to_owned);
            save_at(home, &record)?;
            // Compare-and-replace: only the key recorded above goes.
            replace_at_if(home, |now| copied.as_ref().is_none_or(|copied| copied == now))?;
            Ok(CloneCheck::Cloned)
        }
        CopyState::SettledHere => {
            // Settled before `cloned_on` existed: this box takes it.
            if record.cloned_on.is_none()
                && let Some(current) = current
            {
                record.cloned_on = Some(current.to_owned());
                save_at(home, &record)?;
            }
            Ok(CloneCheck::AlreadyCloned)
        }
        CopyState::Own => {
            let Some(current) = current else { return Ok(CloneCheck::Unknown) };
            if record.host_fingerprint.as_deref() == Some(current) {
                return Ok(CloneCheck::Same);
            }
            // Joined before cmux-host bound this box's instance id (the same box, now under
            // it), or before fingerprints existed: this box takes it.
            record.host_fingerprint = Some(current.to_owned());
            save_at(home, &record)?;
            Ok(CloneCheck::Adopted)
        }
    }
}

/// Whether `relay` is the one a join to `hub` writes ([`configure_mesh_relay_at`]): the join's
/// credential, no `tokenCommand`, and `hub`'s origin. The one rule both sides use: a sign-in's
/// join leaves any other relay as it is ([`own_relay_at`]), and a leave (`leave::remove_local`)
/// removes only this one, so a relay the person set up survives a sign-out.
fn join_relay_for(relay: &crate::mesh_http::MeshRelayConfig, hub: &str) -> bool {
    let Ok(hub) = origin(Some(hub.to_owned())) else { return false };
    relay.credential.as_deref() == Some("join")
        && relay.token_command.is_empty()
        && origin(Some(relay.url.clone())).ok().as_deref() == Some(hub.as_str())
}

/// Whether config.json at `config_path` holds a `meshRelay` no join to `hub` wrote: one the
/// person set up (a `tokenCommand`, a credential of its own) or a join's for another hub. A
/// sign-in's join never replaces it (`enroll.rs`, `recovery::complete`), so the join's relay is
/// only ever one the sign-in wrote, and a sign-out (`leave::remove_local`) removes only that.
fn own_relay_at(config_path: &std::path::Path, hub: &str) -> Result<bool> {
    let config = crate::config::Config::load_from(config_path)?;
    Ok(config.mesh_relay.as_ref().is_some_and(|relay| !join_relay_for(relay, hub)))
}

/// Writes the join's `meshRelay` for a join to `hub` just committed: a sign-in's join
/// (`sign_in`) leaves a relay the person set up as it is ([`own_relay_at`]); the record stays
/// joined, and its sign-out never touches that relay. A join the person ran writes it, as always.
fn relay_for_join_at(config_path: &std::path::Path, hub: &str, sign_in: bool) -> Result<()> {
    if sign_in && own_relay_at(config_path, hub)? {
        return Ok(());
    }
    configure_mesh_relay_at(config_path, hub)
}

fn configure_mesh_relay_at(config_path: &std::path::Path, hub: &str) -> Result<()> {
    let mut config = crate::config::Config::load_from(config_path)?;
    let previous = config.mesh_relay.take();
    // The owner's own choice of team messaging stays across a rejoin or a repair.
    let team_messaging = previous.as_ref().is_none_or(|relay| relay.team_messaging);
    // So does the owner's direct-send switch: a rejoin never turns it on, nor off.
    let direct_send = previous.as_ref().is_some_and(|relay| relay.direct_send);
    let control_from = joined_control_from(previous);
    config.mesh_relay = Some(crate::mesh_http::MeshRelayConfig {
        url: hub.to_owned(),
        token_command: Vec::new(),
        credential: Some("join".to_owned()),
        team_messaging,
        control_from,
        direct_send,
    });
    config.save_with_writer(|path, bytes| recovery::write_durable(path, bytes, true))
}

/// Adds the `sameUser` entry to a joined `meshRelay` that has none, or marks the one an older
/// join wrote with its `maxPolicy` ([`crate::mesh_relay_config::upgrade_join_entries`]). True when it changed config.json.
/// A relay that is not the join's, or none, is left alone.
fn add_same_user_control() -> Result<bool> {
    let _lock = join_lock()?;
    let mut config = crate::config::Config::load()?;
    let Some(relay) = config.mesh_relay.as_mut() else { return Ok(false) };
    if relay.credential.as_deref() != Some("join") {
        return Ok(false);
    }
    let upgraded = crate::mesh_relay_config::upgrade_join_entries(&mut relay.control_from);
    if relay.control_from.iter().any(|entry| entry.same_user) {
        if upgraded {
            config.save_with_writer(|path, bytes| recovery::write_durable(path, bytes, true))?;
        }
        return Ok(upgraded);
    }
    // Only the entry is added; every other relay setting stays as the owner left it.
    relay.control_from.push(crate::mesh_http::MeshControlFrom::same_user());
    config.save_with_writer(|path, bytes| recovery::write_durable(path, bytes, true))?;
    Ok(true)
}

/// The control senders a join writes: the owner's own entries kept, plus the person's own
/// other machines (`{"sameUser": true}`) unless an entry already says what `sameUser` gets.
fn joined_control_from(
    previous: Option<crate::mesh_http::MeshRelayConfig>,
) -> Vec<crate::mesh_http::MeshControlFrom> {
    let mut control_from = previous.map(|relay| relay.control_from).unwrap_or_default();
    crate::mesh_relay_config::upgrade_join_entries(&mut control_from);
    if !control_from.iter().any(|entry| entry.same_user) {
        control_from.push(crate::mesh_http::MeshControlFrom::same_user());
    }
    control_from
}

fn mesh_relay_configured() -> bool {
    crate::config::Config::load()
        .ok()
        .and_then(|config| config.mesh_relay)
        .is_some_and(|relay| relay.credential.as_deref() == Some("join"))
}

/// Records the person the hub names for the credential that asked (`host join --status`
/// repairs an older join). Like [`record_auth_result`], only that credential's record changes.
fn record_user_id(token: &str, user_id: Option<String>) -> Result<()> {
    let Some(user_id) = user_id else { return Ok(()) };
    let _lock = join_lock()?;
    if let Some(mut record) = load()?
        && record.credential == token
        && record.user_id.as_deref() != Some(user_id.as_str())
    {
        record.user_id = Some(user_id);
        save(&record)?;
    }
    Ok(())
}

/// This box's joined identity. A record copied here from the box that joined it names that other
/// box, so it is not this one's: the same check [`machine_credential`] makes.
pub(crate) fn identity() -> Result<Option<MachineIdentity>> {
    Ok(machine_credential()?.as_ref().map(MachineIdentity::from_record))
}

/// A stored hub origin, checked as `host join` checks it.
pub(crate) fn hub_origin(value: &str) -> Result<String> {
    origin(Some(value.to_owned()))
}

/// The person a cmux access token acts for (its `sub` claim, unverified: the hub checks the
/// token itself), as a safe id, for `host enroll-self --user-id` (`cmux device add` joins the Mac
/// that ran it as that person). None for a token that is no JWT or names no one.
pub fn access_token_user(token: &str) -> Option<String> {
    sent_credential::user(token).and_then(|user| safe_id(&user))
}

/// `value`, else `CMUX_PLATFORM_ORIGIN`, else production, checked as `host join` checks it.
pub(crate) fn hub_origin_or_default(value: Option<String>) -> Result<String> {
    origin(value)
}

/// The relay client reads the joined bearer in-process from the owner-only store.
/// It never receives a command, URL or environment value containing the credential.
pub(crate) fn read_join_credential(hub_origin: &str) -> Result<String> {
    let record = load()?.ok_or_else(|| anyhow!("machine credential is missing"))?;
    anyhow::ensure!(!record.revoked, "revoked: run machine add again");
    anyhow::ensure!(
        !copied_here(&state_dir(), &record, host_fingerprint::current().as_deref()),
        "cloned: this machine's state was copied from another machine; paste a new join line"
    );
    anyhow::ensure!(
        origin(Some(record.hub_origin.clone()))? == origin(Some(hub_origin.to_owned()))?,
        "machine credential belongs to another hub"
    );
    anyhow::ensure!(record.credential.starts_with("cmm_"), "machine credential is malformed");
    Ok(record.credential)
}

/// At daemon start: a daemon whose own state holds a join or consent keeps the account-wide
/// requirement. One with neither (every Windows daemon: no OS account home is read there)
/// needs no authority, so the start never depends on it.
pub(crate) fn retain_own_machine_consent_requirement() -> Result<()> {
    if !super::machine_consent::has_own_requirement(&consent_home())? {
        return Ok(());
    }
    authority()?.retain_own_requirement()
}

fn load_consent() -> Consent {
    serde_json::from_value(consent_status()["consent"].clone()).unwrap_or_default()
}

/// Held until redeem and both local writes complete. A competing installer exits
/// without redeeming; it can safely retry after this process finishes.
pub(crate) fn join_lock() -> Result<HeldLock> {
    crate::config::private_state_dir(&state_dir())?;
    join_lock_at(&state_dir())
}

/// [`join_lock`] in acpmux home `home` (made private by the caller).
fn join_lock_in(home: &std::path::Path) -> Result<HeldLock> {
    join_lock_at(home)
}

fn join_lock_at(dir: &std::path::Path) -> Result<HeldLock> {
    let file = crate::config::private_state_rw(&dir.join("machine-join.lock"))?;
    HeldLock::take(file, "another machine join is in progress; retry when it finishes")
}

pub(crate) fn credential_present() -> Result<bool> {
    let current = host_fingerprint::current();
    load()
        .map(|value| {
            value.is_some_and(|record| !copied_here(&state_dir(), &record, current.as_deref()))
        })
        .map_err(|e| store_error_from(e).into())
}

pub(crate) fn already_joined(replace: bool, report: Report) -> Result<bool> {
    let Some(record) = load().map_err(store_error_from)? else { return Ok(false) };
    // A copy of another box's join is no join of this one: the new join line makes one.
    if replace
        || join_incomplete()?
        || copied_here(&state_dir(), &record, host_fingerprint::current().as_deref())
    {
        return Ok(false);
    }
    // No released build created pre-marker credentials. Even branch-only local
    // state must persist the shared requirement before idempotent success.
    let sign_in = record.joined_by.as_deref() == Some(JOINED_BY_SIGN_IN);
    authority().and_then(|authority| authority.enroll_as(sign_in)).map_err(store_error_from)?;
    // Repair a previous config-save failure before reporting idempotent success. A sign-in's
    // join leaves a relay the person set up as it is.
    relay_for_join_at(&crate::config::Config::path(), &record.hub_origin, sign_in)
        .map_err(store_error_from)?;
    match report {
        Report::Quiet => {}
        Report::Json => {
            warn_existing_helpers();
            crate::cli::output::print_json(
                &json!({"joined":false,"alreadyJoined":true,"machineId":record.machine_id,"teamId":record.team_id,"name":record.name,"hubOrigin":record.hub_origin}),
            );
        }
        Report::Text => {
            warn_existing_helpers();
            println!("already joined ({})", record.machine_id);
        }
    }
    Ok(true)
}

fn warn_existing_helpers() {
    eprintln!(
        "Existing Computer Use helpers may remain ungated until they exit; close them normally and use updated builds before enabling remote access."
    );
}

fn store_error() -> crate::cli::errors::AppError {
    store_error_with("local machine store unavailable".to_string())
}

/// [`store_error`] that names what failed (a path refused, a lock held, a write that did not land),
/// so a join that stops here says why. Its cause is a local file or lock error, never a token.
pub(crate) fn store_error_from(cause: impl std::fmt::Display) -> crate::cli::errors::AppError {
    store_error_with(format!("local machine store unavailable: {cause:#}"))
}

fn store_error_with(message: String) -> crate::cli::errors::AppError {
    crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.store", message)
        .with_exit(5)
}

pub async fn join_with_token(
    hub: Option<String>,
    name: Option<String>,
    replace: bool,
    json_out: bool,
    token: Option<String>,
) -> Result<()> {
    let before = credential_now().await;
    recovery::join(hub, name, replace, Report::from_json(json_out), token, None).await?;
    // A new join opens the consent enrollment window: the daemon's carrier, when it starts on
    // this join, pins this Mac's own app key and its peers' with no ask (`consent_grant.rs`).
    let after = credential_now().await;
    if after.is_some() && after != before {
        let _ = tokio::task::spawn_blocking(|| {
            authority().and_then(|authority| {
                super::consent_grant::open_window(&authority, crate::store::now_ms())
            })
        })
        .await;
    }
    Ok(())
}

/// The joined record's credential now, when there is a live one.
async fn credential_now() -> Option<String> {
    tokio::task::spawn_blocking(|| {
        machine_credential().ok().flatten().filter(|record| !record.revoked).map(|r| r.credential)
    })
    .await
    .ok()
    .flatten()
}

/// `acpmux machine leave` (`cloud_join/leave.rs`).
pub async fn leave(local_only: bool, json_out: bool) -> Result<()> {
    leave::run(local_only, json_out).await
}

pub(crate) fn join_incomplete() -> Result<bool> {
    Ok(recovery::pending_origin()?.is_some())
}

/// Update only the credential that made the request. A late response from an old
/// replaced credential must never revoke or timestamp the replacement.
pub(crate) fn record_auth_result(token: &str, revoked: bool, heartbeat: bool) -> Result<()> {
    record_auth_result_at(&state_dir(), token, revoked, heartbeat, crate::store::now_ms())
}

/// [`record_auth_result`] in acpmux home `home` at `now` (epoch ms).
fn record_auth_result_at(
    home: &std::path::Path,
    token: &str,
    revoked: bool,
    heartbeat: bool,
    now: u64,
) -> Result<()> {
    // A heartbeat lands every few seconds; the stored one only has to stay inside the doctor's
    // `HEARTBEAT_WITHIN_MS`. A fresh one already on disk is no change: no lock, no fsync'd
    // rewrite of the credential file (it ran every 10 s on every joined machine).
    if heartbeat
        && !revoked
        && load_at(home)?.is_some_and(|record| {
            record.credential == token && !record.revoked && heartbeat_fresh(&record, now)
        })
    {
        return Ok(());
    }
    crate::config::private_state_dir(home)?;
    let _lock = join_lock_in(home)?;
    if let Some(mut record) = load_at(home)? {
        if record.credential != token {
            return Ok(());
        }
        let mut changed = false;
        if revoked && !record.revoked {
            record.revoked = true;
            changed = true;
        }
        if heartbeat && !heartbeat_fresh(&record, now) {
            record.last_heartbeat = Some(now.to_string());
            changed = true;
        }
        if changed {
            save_at(home, &record)?;
        }
    }
    Ok(())
}

/// How old a stored heartbeat may be before a new one is written: a third of the doctor's
/// `HEARTBEAT_WITHIN_MS`, so `host join --status` never reads a live machine as stale.
const HEARTBEAT_PERSIST_MS: u64 = crate::cli::host_join_doctor::HEARTBEAT_WITHIN_MS / 3;

fn heartbeat_fresh(record: &MachineCredential, now_ms: u64) -> bool {
    record
        .last_heartbeat
        .as_deref()
        .and_then(|at| at.parse::<u64>().ok())
        .and_then(|at| now_ms.checked_sub(at))
        .is_some_and(|age| age < HEARTBEAT_PERSIST_MS)
}

/// Records the WireGuard public key the hub now holds for `machine_id` (a rekey,
/// `crate::machine_tunnel`). Only that machine's record changes.
pub(crate) fn record_wg_public_key(machine_id: &str, wg_public_key: &str) -> Result<()> {
    let _lock = join_lock()?;
    if let Some(mut record) = load()?
        && record.machine_id == machine_id
        && record.wg_public_key != wg_public_key
    {
        record.wg_public_key = wg_public_key.to_owned();
        save(&record)?;
    }
    Ok(())
}

pub async fn status(hub: Option<String>, json_out: bool) -> Result<()> {
    let pending_origin = recovery::pending_origin()?;
    let fallback_hub = pending_origin.clone().unwrap_or(origin(hub)?);
    // Report-only: a copy is found from the fingerprint (`copied_here`); marking it and the
    // fresh node key are the daemon start's and `host join`'s.
    let record = load()?.unwrap_or(MachineCredential {
        name: local_name(None),
        hub_origin: fallback_hub,
        ..Default::default()
    });
    let daemon = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        crate::client::Client::connect(&crate::config::socket_path()),
    )
    .await;
    let running = matches!(daemon, Ok(Ok(_)));
    let cloned = copied_here(&state_dir(), &record, host_fingerprint::current().as_deref());
    // A copy holds no credential of this box: not present, and the copied public key is not
    // this box's (its own appears with its new join).
    let wg_public_key = (!cloned).then_some(record.wg_public_key.clone());
    let mut out = json!({"credentialPresent": !record.credential.is_empty() && !cloned, "machineId": record.machine_id, "teamId": record.team_id, "hubOrigin": record.hub_origin, "hubReachable": false, "lastHeartbeat": record.last_heartbeat, "revoked": record.revoked, "wgPublicKey": wg_public_key, "consent": load_consent(), "credentialStore":"file", "credentialPath":credential_path(), "credentialMode":if record.credential.is_empty() || cloned { None } else { Some("0600") }, "daemonRunning":running, "meshRelayConfigured":mesh_relay_configured(), "userId": record.user_id, "build": crate::hub::build(), "channel":null});
    out["joinIncomplete"] = json!(pending_origin.is_some());
    // The copy's own answer: its credential is the original box's and is never sent from here.
    out["cloned"] = json!(cloned);
    if cloned {
        out["hint"] = json!(CLONED_HINT);
    }
    out["helperConsent"] =
        json!({"state":"unknown","reason":"running helper consent support has not been verified"});
    out["lastRefusal"] = consent_status()["lastRefusal"].clone();
    // As the account this machine is joined as now reads it, as the app and the session gate do
    // (`for_this_account`): no other account's signedInMachines grant, answer or ask.
    out = for_this_account(out);
    if !record.credential.is_empty() && !cloned {
        // GET is read-only: doctor must never replace the daemon's live sessions.
        let hub = origin(Some(record.hub_origin.clone()))?;
        let answer = hub_client(&hub, Some(&record.credential))?.machine_redeem_self().await;
        let status = match answer {
            Ok(body) => {
                // Repair an older join: record the person the hub now names.
                let user_id = body.user_id.as_ref().and_then(|user| safe_id(&user.to_string()));
                if user_id.is_some() && record.user_id != user_id {
                    record_user_id(&record.credential, user_id.clone())?;
                    out["userId"] = json!(user_id);
                }
                // A machine joined before `sameUser` existed has `controlFrom: []`: add the
                // person's own machines now. The daemon reads controlFrom at its start.
                if user_id.is_some() && add_same_user_control()? {
                    out["controlFromAdded"] = json!("sameUser");
                    out["restartNeeded"] = json!(true);
                }
                Some(200)
            }
            Err(error) => cmux_cloud_client::ApiError::from_api(error).await.status,
        };
        if let Some(status) = status {
            out["hubReachable"] = json!(true);
            if status == 401 {
                record_auth_result(&record.credential, true, false)?;
                out["revoked"] = json!(true);
            }
        }
    }
    if json_out {
        crate::cli::output::print_json(&out);
    } else if out["joinIncomplete"] == true {
        // retry-prompt-ok: join resumes a side-effecting enrollment the person started.
        println!("join incomplete, rerun join");
    } else if cloned {
        println!("cloned: {CLONED_HINT}");
    } else if out["revoked"] == true {
        println!("revoked: run machine add again");
    } else {
        println!(
            "credential: {}\nhub: {}\nlast heartbeat: {}",
            if out["credentialPresent"] == true { "present" } else { "missing" },
            if out["hubReachable"] == true { "reachable" } else { "unreachable" },
            out["lastHeartbeat"].as_str().unwrap_or("never")
        );
    }
    Ok(())
}

/// The person-proven local daemon RPC calls this writer, and so does the CLI run under sudo as
/// this Mac's admin (`consent_admin.rs`). A plain shell has no person key and no admin proof.
pub(crate) fn set_consent_for_person(surface: &str, granted: bool) -> Result<Consent> {
    authority()?.set(surface, granted)
}

/// `machine_consent_set {surface, granted: null}`: clears the person's own setting of `screen` or
/// `control` here, so the signed grants decide again (`consent_grant.rs`). The person only.
pub(crate) fn clear_consent_for_person(surface: &str) -> Result<Consent> {
    authority()?.set_local(surface, None, machine_user_id().as_deref())
}

/// `_acpmux/machine_consent_get`'s answer: [`consent_status_for`] plus the pinned grantors, the
/// pending grantor ask and the last lines of the grant log (`consent_grant.rs`).
pub(crate) fn consent_status_with_grants(
    params: &Value,
    own: Option<&super::consent_grant::OwnGrantor>,
) -> Value {
    let mut status = consent_status_for(params);
    let account = machine_user_id();
    if let Some(fields) = status.as_object_mut() {
        if let Ok(authority) = authority() {
            fields.extend(super::consent_grant::status_fields(&authority, account.as_deref(), own));
        }
        fields.insert("account".into(), json!(account));
    }
    status
}

/// Grants "control for my other signed-in machines" for `account`, the account a control
/// approval was admitted for (`share_host/approval.rs`: the owner's tap on their own device,
/// signed by its device key). It holds only for the account this machine is joined as, so an
/// approval for any other account, or a machine with no join, grants nothing.
pub(crate) fn grant_signed_in_machines_for(account: &str) -> std::result::Result<(), String> {
    grant_signed_in_machines_as(account, machine_user_id().as_deref(), |user| {
        authority()?.set_as(SIGNED_IN_MACHINES, true, Some(user))?;
        Ok(())
    })
}

/// [`grant_signed_in_machines_for`], given the account this machine is joined as and the writer.
pub(crate) fn grant_signed_in_machines_as(
    account: &str,
    joined_as: Option<&str>,
    write: impl FnOnce(String) -> Result<()>,
) -> std::result::Result<(), String> {
    match joined_as {
        None => Err("this Mac is not joined to an account".into()),
        Some(joined) if joined != account => {
            Err("this Mac is joined as another account than the one that allowed it".into())
        }
        Some(joined) => write(joined.to_owned()).map_err(|e| e.to_string()),
    }
}

/// This machine's consent and the account it is joined as, read now (blocking file reads).
pub fn signed_in_machines_granted_here() -> (bool, Option<String>) {
    let account = machine_user_id();
    let granted = signed_in_machines_granted(&consent_status_for(&json!({})), account.as_deref());
    (granted, account)
}

/// The consent status the gates read. With `{"use": "localComputerUse"}` (the app asking
/// for its Computer Use helper, which serves only this Mac's own sessions), a requirement only
/// sign-in joins made gates nothing ([`machine_consent::Authority::status_for`]); every other
/// caller gets the requirement as it is.
pub(crate) fn consent_status_for(params: &Value) -> Value {
    let local = params.get("use").and_then(Value::as_str) == Some("localComputerUse");
    for_this_account(
        authority()
            .map(|authority| authority.status_for(local))
            .unwrap_or_else(|_| consent_status()),
    )
}

/// A consent status as it holds for the account this machine is joined as now
/// ([`super::machine_consent::for_account`]): what the app and the session gate read.
pub(crate) fn for_this_account(status: Value) -> Value {
    super::machine_consent::for_account(status, machine_user_id().as_deref())
}

/// [`record_consent_refusal`], naming the machine that asked (a host the hub lists). A
/// `signedInMachines` ask names the account it was made for.
#[cfg(feature = "hub-carrier")]
pub(crate) fn record_consent_refusal_from(surface: &str, from: Option<&str>) -> Result<()> {
    let user = (surface == SIGNED_IN_MACHINES).then(machine_user_id).flatten();
    authority()?.refused_by(surface, from, user.as_deref())
}

/// The hub's generated client (cmux-cloud-client), as `bearer` when given,
/// with the join's 10 s deadline and no redirects.
pub(crate) fn hub_client(hub: &str, bearer: Option<&str>) -> Result<cmux_cloud_client::Client> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_cloud_client::client_for(
        hub,
        bearer,
        None,
        concat!("acpmux/", env!("CARGO_PKG_VERSION")),
        std::time::Duration::from_secs(10),
    )
    .context("build hub client")
}

pub(crate) fn http_client() -> Result<reqwest::Client> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    crate::happy_dial::http_client()
        .default_headers(cmux_build_space::headers()?)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .context("build hub client")
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_store_error_names_its_cause() {
        // 2026-11-21: a join that stopped at the store said only "unavailable".
        let cause = std::io::Error::other("home is a symlink");
        let error = super::store_error_from(cause);
        assert_eq!(error.message, "local machine store unavailable: home is a symlink");
        assert_eq!(super::store_error().message, "local machine store unavailable");
    }

    use super::{MachineCredential, MachineIdentity, origin, parse_token_text};

    /// A control approval's grant is written only for the account this machine is joined as.
    #[test]
    fn a_carried_control_grant_is_only_for_the_joined_account() {
        let written = std::cell::RefCell::new(Vec::new());
        let write = |user: String| {
            written.borrow_mut().push(user);
            Ok(())
        };
        assert!(super::grant_signed_in_machines_as("user-1", None, write).is_err());
        assert!(super::grant_signed_in_machines_as("user-1", Some("user-2"), write).is_err());
        assert!(written.borrow().is_empty(), "nothing written for another account or no join");
        assert_eq!(super::grant_signed_in_machines_as("user-1", Some("user-1"), write), Ok(()));
        assert_eq!(*written.borrow(), ["user-1"]);
        let failed = super::grant_signed_in_machines_as("user-1", Some("user-1"), |_| {
            Err(anyhow::anyhow!("consent store unavailable"))
        });
        assert_eq!(failed.unwrap_err(), "consent store unavailable");
    }

    #[test]
    fn join_token_is_shell_safe_after_shared_line_reader() {
        assert_eq!(parse_token_text("cmj_abc-123_").unwrap(), "cmj_abc-123_");
        assert!(parse_token_text("cmj_abc!").is_err());
        assert!(parse_token_text("cmj_").is_err());
        assert!(parse_token_text("cmxt1_ticket").is_err());
    }
    #[test]
    fn join_origin_cannot_carry_secrets_paths_or_non_http_schemes() {
        for url in [
            "https://secret@example.com",
            "https://example.com/path",
            "https://example.com?token=secret",
            "ftp://localhost",
            "http://example.com",
        ] {
            let error = origin(Some(url.to_owned())).unwrap_err().to_string();
            assert!(!error.contains("secret"));
        }
        assert_eq!(
            origin(Some("https://EXAMPLE.com:443/".to_owned())).unwrap(),
            "https://example.com"
        );
        assert!(origin(Some("http://127.0.0.1:1234".to_owned())).is_ok());
    }

    #[cfg(unix)]
    fn joined_on(home: &std::path::Path, fingerprint: Option<&str>) -> Vec<u8> {
        let record = super::MachineCredential {
            credential: "cmm_original".into(),
            machine_id: "machine_original".into(),
            team_id: "team".into(),
            name: "original".into(),
            hub_origin: "https://example.com".into(),
            wg_public_key: "original-key".into(),
            credential_generation: 1,
            host_fingerprint: fingerprint.map(str::to_owned),
            ..Default::default()
        };
        super::save_at(home, &record).unwrap();
        crate::cli::mesh_node_key::load_or_create_at(home).unwrap();
        std::fs::read(home.join("node.wg.key")).unwrap()
    }

    /// Two VMs made from one image share a host name: each one joined under its own name
    /// (`machine join --name`) is that name to its peers, so neither shadows the other on the
    /// hub. A default join, a revoked or copied record, or a name no session name may be keeps
    /// the host name.
    #[test]
    #[cfg(unix)]
    fn a_machine_named_at_its_join_is_that_name_to_its_peers() {
        let home = tempfile::tempdir().unwrap();
        let named_at = |record: &super::MachineCredential, here: Option<&str>| {
            super::save_at(home.path(), record).unwrap();
            crate::machine_record::joined_name_at(home.path(), here)
        };
        assert_eq!(crate::machine_record::joined_name_at(home.path(), Some("fp")), None);
        let record = super::MachineCredential {
            credential: "cmm_x".into(),
            name: "lane-7".into(),
            host_fingerprint: Some("fp".into()),
            named: true,
            ..Default::default()
        };
        assert_eq!(named_at(&record, Some("fp")).as_deref(), Some("lane-7"));
        assert_eq!(named_at(&record, None).as_deref(), Some("lane-7"), "no fingerprint here");
        let default = super::MachineCredential { named: false, ..record.clone() };
        assert_eq!(named_at(&default, Some("fp")), None, "took the host name");
        let revoked = super::MachineCredential { revoked: true, ..record.clone() };
        assert_eq!(named_at(&revoked, Some("fp")), None);
        let cloned = super::MachineCredential { cloned: true, ..record.clone() };
        assert_eq!(named_at(&cloned, Some("fp")), None);
        assert_eq!(named_at(&record, Some("other-box")), None, "a copy on another box");
        let odd = super::MachineCredential { name: "Lane 7".into(), ..record.clone() };
        assert_eq!(named_at(&odd, Some("fp")), None, "not a session name");
        // An older build's record has no `named`: the host name, as before.
        let older: super::MachineCredential =
            serde_json::from_str(r#"{"credential":"cmm_x","machine_id":"m","team_id":"t","name":"lane-7","hub_origin":"https://h","last_heartbeat":null,"revoked":false,"wgPublicKey":"k"}"#).unwrap();
        assert!(!older.named);
    }

    /// The cmux link's Cloud tunnel runs only for a live join of this box: a sign-out's leave
    /// mark, a queued revoke of its own, a revoked record or no record at all stop it.
    #[test]
    #[cfg(unix)]
    fn the_tunnel_runs_only_for_a_live_join_of_this_box() {
        let home = tempfile::tempdir().unwrap();
        assert_eq!(super::joined_device_at(home.path()), None, "not joined");
        let current = super::host_fingerprint::current();
        joined_on(home.path(), current.as_deref());
        let mut record = super::load_at(home.path()).unwrap().unwrap();
        // The tunnel attaches only a `machine_` id.
        record.machine_id = "vm_1".into();
        super::save_at(home.path(), &record).unwrap();
        assert_eq!(super::joined_device_at(home.path()), None);
        record.machine_id = "machine_original".into();
        super::save_at(home.path(), &record).unwrap();
        assert_eq!(
            super::joined_device_at(home.path()),
            Some(super::JoinedDevice {
                machine_id: "machine_original".into(),
                team_id: "team".into(),
                name: "original".into(),
                hub_origin: "https://example.com".into(),
            })
        );

        let leave = home.path().join(super::enroll::LEAVE_FILE);
        std::fs::write(&leave, b"{}").unwrap();
        assert_eq!(super::joined_device_at(home.path()), None, "a sign-out's leave is pending");
        std::fs::remove_file(&leave).unwrap();
        assert!(super::joined_device_at(home.path()).is_some());

        // A revoke an earlier join's sign-out still owes (its row, and its credential) is not this
        // join's: the sign-in since enrolled this one, so the tunnel runs (the probe
        // cloud-carrier-ssh-failover: a shared runner home kept ssh `no_tunnel` for every run).
        let earlier = super::MachineCredential {
            credential: "cmm_earlier".into(),
            machine_id: "machine_earlier".into(),
            hub_origin: "https://other.example.com".into(),
            ..Default::default()
        };
        super::to_revoke::queue(home.path(), &super::to_revoke::Row::of(&earlier, false)).unwrap();
        super::to_revoke::queue(home.path(), &super::to_revoke::Row::of(&earlier, true)).unwrap();
        assert!(super::to_revoke::any_queued(home.path()));
        assert!(super::joined_device_at(home.path()).is_some(), "an earlier join's revoke");
        // One owed for this join itself stops it, by its row or by its credential.
        super::to_revoke::queue(home.path(), &super::to_revoke::Row::of(&record, false)).unwrap();
        assert_eq!(super::joined_device_at(home.path()), None, "this join's row is queued");
        let own_credential =
            super::MachineCredential { machine_id: String::new(), ..record.clone() };
        let other = tempfile::tempdir().unwrap();
        joined_on(other.path(), current.as_deref());
        super::to_revoke::queue(other.path(), &super::to_revoke::Row::of(&own_credential, true))
            .unwrap();
        assert_eq!(super::joined_device_at(other.path()), None, "this join's credential is queued");
        for path in std::fs::read_dir(home.path().join("machine-join.to-revoke")).unwrap() {
            std::fs::remove_file(path.unwrap().path()).unwrap();
        }
        assert!(super::joined_device_at(home.path()).is_some());

        record.revoked = true;
        super::save_at(home.path(), &record).unwrap();
        assert_eq!(super::joined_device_at(home.path()), None, "revoked");
    }

    /// Review F2 at 9e91bcea: the clone check the cmux link shares, by the home it names.
    /// A copy whose key could not be replaced (not marked yet) is a copy, as is a marked one;
    /// the box that joined, an unjoined home and an unknown box are not.
    #[test]
    #[cfg(unix)]
    fn the_shared_clone_check_reads_the_named_home() {
        let home = tempfile::tempdir().unwrap();
        assert!(!super::copied_at(home.path(), Some("box-b")), "not joined");
        joined_on(home.path(), Some("box-a"));
        assert!(!super::copied_at(home.path(), Some("box-a")));
        assert!(!super::copied_at(home.path(), None));
        assert!(super::copied_at(home.path(), Some("box-b")), "an unsettled copy");
        let mut record = super::load_at(home.path()).unwrap().unwrap();
        record.cloned = true;
        super::save_at(home.path(), &record).unwrap();
        assert!(
            super::copied_at(home.path(), Some("box-a")) && super::copied_at(home.path(), None)
        );
    }

    /// Review F1 at d1e8f0ed: a copy found and not settled records its node key as copied
    /// before anything else, so a leave that then deletes the record (and keeps the key the
    /// link adopted) leaves the evidence behind; a settled copy's fresh key is never recorded.
    #[test]
    #[cfg(unix)]
    fn a_found_copy_is_recorded_before_a_leave_removes_its_record() {
        use crate::cli::mesh_node_key::{COPIED_KEY, serves_copied_key};
        let home = tempfile::tempdir().unwrap();
        joined_on(home.path(), Some("box-a"));
        // The link adopted the key: a leave keeps it.
        std::fs::create_dir_all(home.path().join("link")).unwrap();
        let record = serde_json::json!({ "key_dir": home.path() });
        std::fs::write(home.path().join("link/key-adopted.json"), record.to_string()).unwrap();
        assert!(!serves_copied_key(home.path()));
        assert!(super::copied_at(home.path(), Some("box-b")));
        assert!(serves_copied_key(home.path()), "the found copy was not recorded");
        let removed = super::leave::remove_local(home.path(), false).unwrap();
        assert!(removed.contains(&"credential") && !removed.contains(&"nodeKey"), "{removed:?}");
        assert!(super::copied_at(home.path(), Some("box-b")), "the leave erased the evidence");
        assert!(super::copied_at(home.path(), None));
        // The settled path: recorded before the replacement, which then names the old key.
        let settled = tempfile::tempdir().unwrap();
        joined_on(settled.path(), Some("box-a"));
        assert_eq!(
            super::settle_clone_at(settled.path(), Some("box-b")).unwrap(),
            super::CloneCheck::Cloned
        );
        assert!(settled.path().join(COPIED_KEY).is_file());
        assert!(!serves_copied_key(settled.path()), "the fresh key is this box's");
        // A record already settled (`cloned`) names a fresh key: never recorded as copied.
        let fresh = tempfile::tempdir().unwrap();
        joined_on(fresh.path(), Some("box-a"));
        let mut record = super::load_at(fresh.path()).unwrap().unwrap();
        record.cloned = true;
        super::save_at(fresh.path(), &record).unwrap();
        assert!(super::copied_at(fresh.path(), Some("box-b")));
        assert!(!fresh.path().join(COPIED_KEY).exists());
    }

    /// Review F1 at 6b797bbf: a copy settled on box B (fresh key B) and copied again to C,
    /// as it was or after B joined again, is found and settled again on C, and every copied
    /// key stays named; B itself keeps its key.
    #[test]
    #[cfg(unix)]
    fn a_copy_of_a_settled_copy_is_found_and_settled_again() {
        use crate::cli::mesh_node_key::{public_key_at, serves_copied_key};
        for rejoined in [false, true] {
            let home = tempfile::tempdir().unwrap();
            joined_on(home.path(), Some("box-a"));
            let key_a = public_key_at(home.path()).unwrap();
            assert_eq!(
                super::settle_clone_at(home.path(), Some("box-b")).unwrap(),
                super::CloneCheck::Cloned
            );
            let key_b = public_key_at(home.path()).unwrap();
            assert_ne!(key_b, key_a);
            if rejoined {
                let mut record = super::load_at(home.path()).unwrap().unwrap();
                record.cloned = false;
                record.cloned_on = None;
                record.host_fingerprint = Some("box-b".into());
                super::save_at(home.path(), &record).unwrap();
            }
            // B: its own key, settled or joined there.
            let on_b = super::load_at(home.path()).unwrap().unwrap();
            assert_ne!(
                super::copy_state(home.path(), &on_b, Some("box-b")),
                super::CopyState::Unsettled
            );
            assert!(!serves_copied_key(home.path()), "B's own key is named copied");
            assert_eq!(
                super::settle_clone_at(home.path(), Some("box-b")).unwrap(),
                if rejoined { super::CloneCheck::Same } else { super::CloneCheck::AlreadyCloned }
            );
            assert_eq!(public_key_at(home.path()), Some(key_b));
            // C: found live, recorded, and settled with a key of its own.
            let on_c = super::load_at(home.path()).unwrap().unwrap();
            assert_eq!(
                super::copy_state(home.path(), &on_c, Some("box-c")),
                super::CopyState::Unsettled
            );
            assert!(super::copied_here(home.path(), &on_c, Some("box-c")));
            assert!(serves_copied_key(home.path()), "the copy of the copy was not recorded");
            assert_eq!(
                super::settle_clone_at(home.path(), Some("box-c")).unwrap(),
                super::CloneCheck::Cloned,
                "rejoined {rejoined}"
            );
            let key_c = public_key_at(home.path()).unwrap();
            assert!(key_c != key_a && key_c != key_b);
            let named: serde_json::Value = serde_json::from_slice(
                &std::fs::read(home.path().join(crate::cli::mesh_node_key::COPIED_KEY)).unwrap(),
            )
            .unwrap();
            let named = named["public_keys"].as_array().unwrap().len();
            assert_eq!(named, 2, "both copied keys stay named (rejoined {rejoined})");
            assert!(!serves_copied_key(home.path()));
        }
    }

    /// A join begun on `box` and not finished, in `home`: `machine-join.pending.json`.
    #[cfg(unix)]
    fn pending_on(home: &std::path::Path, made: &str) {
        use std::os::unix::fs::OpenOptionsExt as _;
        let pending = serde_json::json!({"version": 1, "credential": "cmm_x", "hub": "https://example.com",
            "name": "original", "hostname": "original", "platform": "linux", "wg_public_key": "k",
            "prior": null, "host_fingerprint": made});
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(home.join("machine-join.pending.json"))
            .unwrap();
        std::io::Write::write_all(&mut file, pending.to_string().as_bytes()).unwrap();
    }

    /// Review F1 at 2d63280a: the daemon's start on a copied home reads its evidence (the node
    /// key recorded as copied), then a `host join` runs before the start acts: under the join
    /// lock it replaces the copied key and registers a new one. The start then acts under the
    /// same lock, by compare-and-replace, and keeps the registered key.
    #[test]
    #[cfg(unix)]
    fn a_start_on_a_copied_home_racing_a_host_join_keeps_the_registered_key() {
        use crate::cli::mesh_node_key::{
            load_or_create_at, public_key_at, record_copied_key, replace_copied_at,
            serves_copied_key,
        };
        use base64::Engine as _;
        let home = tempfile::tempdir().unwrap();
        let copied = load_or_create_at(home.path()).unwrap().public_key;
        record_copied_key(home.path()).unwrap();
        let registered = std::rc::Rc::new(std::cell::Cell::new(None));
        let joined = std::rc::Rc::clone(&registered);
        let dir = home.path().to_path_buf();
        super::hooks::AFTER_EVIDENCE.with(|hook| {
            *hook.borrow_mut() = Some(Box::new(move || {
                // What `host join` does, under its lock: the copied key replaced, the new one
                // proposed and registered (`new_pending`, then `complete`).
                let _lock = super::join_lock_in(&dir).unwrap();
                let fresh = replace_copied_at(&dir).unwrap().unwrap().public_key;
                let record = super::MachineCredential {
                    credential: "cmm_here".into(),
                    machine_id: "machine_here".into(),
                    team_id: "team".into(),
                    name: "here".into(),
                    hub_origin: "https://example.com".into(),
                    wg_public_key: base64::engine::general_purpose::STANDARD.encode(fresh),
                    credential_generation: 1,
                    host_fingerprint: super::host_fingerprint::current(),
                    ..Default::default()
                };
                super::save_at(&dir, &record).unwrap();
                joined.set(Some(fresh));
            }));
        });
        super::settle_clone_at_start_in(home.path()).unwrap();
        let registered = registered.get().expect("the join ran");
        assert_ne!(registered, copied);
        assert_eq!(
            public_key_at(home.path()),
            Some(registered),
            "the start deleted the join's key"
        );
        assert!(!serves_copied_key(home.path()));
        // With no join in between, the start replaces the copied key itself.
        let alone = tempfile::tempdir().unwrap();
        let copied = load_or_create_at(alone.path()).unwrap().public_key;
        record_copied_key(alone.path()).unwrap();
        super::settle_clone_at_start_in(alone.path()).unwrap();
        assert!(public_key_at(alone.path()).is_some_and(|now| now != copied));
    }

    /// Review F1 at fb84fe4b: a cmux link refused this copied home and stopped before it
    /// recorded the copied key (its refusal names the key, or none). acpmux's start reads the
    /// refusal, finishes the recording and replaces the key: the copied key never serves.
    #[test]
    #[cfg(unix)]
    fn a_link_refusal_with_no_recorded_key_is_finished_and_the_key_replaced_at_start() {
        use crate::cli::mesh_node_key::{
            COPIED_KEY, LINK_COPIED, load_or_create_at, public_key_at, serves_copied_key,
        };
        use base64::Engine as _;
        for named in [true, false] {
            let home = tempfile::tempdir().unwrap();
            let copied = load_or_create_at(home.path()).unwrap().public_key;
            let copied_b64 = base64::engine::general_purpose::STANDARD.encode(copied);
            // The link dir acpmux finds for this home in tests (`link_dirs_for`).
            let link = home.path().join("link");
            std::fs::create_dir_all(&link).unwrap();
            let mut refusal = serde_json::json!({ "acpmux_home": home.path() });
            if named {
                refusal["public_key"] = serde_json::json!(copied_b64);
            }
            std::fs::write(link.join(LINK_COPIED), refusal.to_string()).unwrap();
            assert!(!home.path().join(COPIED_KEY).exists());
            assert!(serves_copied_key(home.path()), "named {named}");
            assert!(super::copied_from_another_box_at(home.path()));
            super::settle_clone_at_start_in(home.path()).unwrap();
            let recorded = std::fs::read_to_string(home.path().join(COPIED_KEY)).unwrap();
            assert!(recorded.contains(&copied_b64), "the refusal was not finished: {recorded}");
            assert!(public_key_at(home.path()).is_some_and(|now| now != copied), "named {named}");
            if named {
                assert!(!serves_copied_key(home.path()), "the fresh key is this box's");
            }
        }
    }

    /// Review F1 at 2d63280a, the readers: a caller that read the copy's record before the box
    /// settled it and joined again never marks the registered key that replaced the copy's.
    #[test]
    #[cfg(unix)]
    fn a_record_read_before_a_settle_and_rejoin_never_marks_the_new_key() {
        use crate::cli::mesh_node_key::{public_key_at, serves_copied_key};
        let home = tempfile::tempdir().unwrap();
        joined_on(home.path(), Some("box-a"));
        let stale = super::load_at(home.path()).unwrap().unwrap();
        // Box B settles under the join lock, then joins again with its fresh key.
        assert!(matches!(
            super::settle_clone_at(home.path(), Some("box-b")).unwrap(),
            super::CloneCheck::Cloned
        ));
        assert!(!serves_copied_key(home.path()));
        let mut rejoined = stale.clone();
        rejoined.cloned = false;
        rejoined.cloned_on = None;
        rejoined.host_fingerprint = Some("box-b".into());
        super::save_at(home.path(), &rejoined).unwrap();
        let fresh = public_key_at(home.path()).unwrap();
        // The stale reader still answers that its record was a copy, and marks nothing new.
        assert!(super::copied_here(home.path(), &stale, Some("box-b")));
        assert!(!serves_copied_key(home.path()), "the registered key was marked copied");
        assert_eq!(public_key_at(home.path()), Some(fresh));
    }

    /// Review F1 at 7837efd1: a home with a node key and a join begun on another box, with no
    /// machine record yet, is a copy to every caller of the one predicate (the link's adoption
    /// check, the daemon, `host join`'s set-aside); the box that began it is not.
    #[test]
    #[cfg(unix)]
    fn a_pending_join_begun_on_another_box_makes_the_home_a_copy_for_every_caller() {
        use crate::cli::mesh_node_key::{load_or_create_at, serves_copied_key};
        let home = tempfile::tempdir().unwrap();
        crate::config::private_state_dir(home.path()).unwrap();
        load_or_create_at(home.path()).unwrap();
        pending_on(home.path(), "box-a");
        assert!(super::load_at(home.path()).unwrap().is_none(), "no record");
        assert_eq!(super::home_copy_state(home.path(), None, Some("box-a")), super::CopyState::Own);
        assert!(!super::copied_at(home.path(), Some("box-a")));
        assert!(!serves_copied_key(home.path()));
        assert_eq!(
            super::home_copy_state(home.path(), None, Some("box-b")),
            super::CopyState::Unsettled
        );
        assert!(super::copied_at(home.path(), Some("box-b")));
        assert!(serves_copied_key(home.path()), "the copy was not recorded");
        // `host join`'s comparison is the same one.
        assert!(super::other_box(home.path(), Some("box-a"), Some("box-b")));
        assert!(!super::other_box(home.path(), Some("box-a"), Some("box-a")));
        // A record joined here does not hide a pending join copied from elsewhere.
        let mine = super::MachineCredential {
            host_fingerprint: Some("box-b".into()),
            ..Default::default()
        };
        assert!(super::copied_here(home.path(), &mine, Some("box-b")));
    }

    #[test]
    #[cfg(unix)]
    fn the_box_that_joined_keeps_its_credential_and_key() {
        let home = tempfile::tempdir().unwrap();
        let key = joined_on(home.path(), Some("box-a"));
        assert_eq!(
            super::settle_clone_at(home.path(), Some("box-a")).unwrap(),
            super::CloneCheck::Same
        );
        let record = super::load_at(home.path()).unwrap().unwrap();
        assert!(!record.cloned && !super::copied_here(home.path(), &record, Some("box-a")));
        assert_eq!(std::fs::read(home.path().join("node.wg.key")).unwrap(), key);
    }

    #[test]
    #[cfg(unix)]
    fn a_copied_home_is_marked_cloned_with_a_fresh_key_and_the_credential_left_as_it_was() {
        let home = tempfile::tempdir().unwrap();
        let key = joined_on(home.path(), Some("box-a"));
        let before = super::load_at(home.path()).unwrap().unwrap();
        assert!(
            super::copied_here(home.path(), &before, Some("box-b")),
            "a mismatch is a copy before any start"
        );
        assert_eq!(
            super::settle_clone_at(home.path(), Some("box-b")).unwrap(),
            super::CloneCheck::Cloned
        );
        let record = super::load_at(home.path()).unwrap().unwrap();
        assert!(record.cloned);
        // Nothing of the original's enrollment changes: no hub call, the same credential and id.
        assert_eq!(record.credential, before.credential);
        assert_eq!(record.machine_id, before.machine_id);
        assert_eq!(record.host_fingerprint.as_deref(), Some("box-a"));
        let fresh = std::fs::read(home.path().join("node.wg.key")).unwrap();
        assert_ne!(fresh, key, "the copy has its own node key");
        // Sticky: the next start finds it cloned and keeps the new key.
        assert_eq!(
            super::settle_clone_at(home.path(), Some("box-b")).unwrap(),
            super::CloneCheck::AlreadyCloned
        );
        assert_eq!(std::fs::read(home.path().join("node.wg.key")).unwrap(), fresh);
        assert!(
            super::copied_here(home.path(), &record, Some("box-b"))
                && super::copied_here(home.path(), &record, None)
        );
    }

    #[test]
    #[cfg(unix)]
    fn an_older_record_adopts_the_box_it_starts_on_and_no_identity_compares_nothing() {
        let home = tempfile::tempdir().unwrap();
        let key = joined_on(home.path(), None);
        let before = super::load_at(home.path()).unwrap().unwrap();
        assert!(
            !super::copied_here(home.path(), &before, Some("box-a")),
            "no fingerprint is no clone"
        );
        assert_eq!(super::settle_clone_at(home.path(), None).unwrap(), super::CloneCheck::Unknown);
        assert_eq!(
            super::settle_clone_at(home.path(), Some("box-a")).unwrap(),
            super::CloneCheck::Adopted
        );
        let record = super::load_at(home.path()).unwrap().unwrap();
        assert_eq!(record.host_fingerprint.as_deref(), Some("box-a"));
        assert!(!record.cloned);
        assert_eq!(std::fs::read(home.path().join("node.wg.key")).unwrap(), key);
        assert_eq!(
            super::settle_clone_at(home.path(), Some("box-a")).unwrap(),
            super::CloneCheck::Same
        );
        // A box with no OS identity never marks a fingerprinted record cloned.
        let other = tempfile::tempdir().unwrap();
        joined_on(other.path(), Some("box-a"));
        assert_eq!(super::settle_clone_at(other.path(), None).unwrap(), super::CloneCheck::Unknown);
        assert!(!super::load_at(other.path()).unwrap().unwrap().cloned);
        let empty = tempfile::tempdir().unwrap();
        assert_eq!(
            super::settle_clone_at(empty.path(), Some("box-a")).unwrap(),
            super::CloneCheck::NotJoined
        );
    }

    #[test]
    #[cfg(unix)]
    fn an_instance_id_bound_after_the_join_is_the_same_box_not_a_clone() {
        use super::host_fingerprint::TEST_MACHINE_ONLY;
        let home = tempfile::tempdir().unwrap();
        // Joined on machine id "mid-a" before cmux-host bound an instance id.
        let key = joined_on(home.path(), Some("mid-a"));
        TEST_MACHINE_ONLY.with(|cell| *cell.borrow_mut() = Some(Some("mid-a".into())));
        let before = super::load_at(home.path()).unwrap().unwrap();
        assert!(!super::copied_here(home.path(), &before, Some("inst-1")));
        assert_eq!(
            super::settle_clone_at(home.path(), Some("inst-1")).unwrap(),
            super::CloneCheck::Adopted
        );
        let record = super::load_at(home.path()).unwrap().unwrap();
        assert_eq!(record.host_fingerprint.as_deref(), Some("inst-1"));
        assert!(!record.cloned);
        assert_eq!(std::fs::read(home.path().join("node.wg.key")).unwrap(), key);
        // A copy onto another box: another machine id, and a record bound to another instance.
        TEST_MACHINE_ONLY.with(|cell| *cell.borrow_mut() = Some(Some("mid-b".into())));
        assert_eq!(
            super::settle_clone_at(home.path(), Some("inst-2")).unwrap(),
            super::CloneCheck::Cloned
        );
        TEST_MACHINE_ONLY.with(|cell| *cell.borrow_mut() = None);
    }

    #[test]
    #[cfg(unix)]
    fn a_cloud_fork_still_on_the_originals_machine_id_is_a_clone() {
        use super::host_fingerprint::TEST_MACHINE_ONLY;
        // Joined on "mid-a" before a bind, then forked: the fork keeps machine id "mid-a" until
        // it is rekeyed, but cmux-host marked its home with `clone-boot` before this start.
        for marker in [crate::hub::clone_boot::MARKER, crate::hub::clone_boot::DONE] {
            let home = tempfile::tempdir().unwrap();
            let key = joined_on(home.path(), Some("mid-a"));
            std::fs::write(home.path().join(marker), r#"{"from":"m1","to":"m2"}"#).unwrap();
            TEST_MACHINE_ONLY.with(|cell| *cell.borrow_mut() = Some(Some("mid-a".into())));
            let before = super::load_at(home.path()).unwrap().unwrap();
            assert!(super::copied_here(home.path(), &before, Some("inst-2")), "{marker}");
            assert_eq!(
                super::settle_clone_at(home.path(), Some("inst-2")).unwrap(),
                super::CloneCheck::Cloned,
                "{marker}"
            );
            assert_ne!(std::fs::read(home.path().join("node.wg.key")).unwrap(), key);
            TEST_MACHINE_ONLY.with(|cell| *cell.borrow_mut() = None);
        }
    }

    #[test]
    fn an_older_record_reads_unfingerprinted_and_not_cloned() {
        let old = serde_json::json!({"credential":"cmm_x","machine_id":"m","team_id":"t","name":"n",
            "hub_origin":"https://example.com","last_heartbeat":null,"revoked":false,"wgPublicKey":"k"});
        let record: super::MachineCredential = serde_json::from_value(old).unwrap();
        assert_eq!(record.host_fingerprint, None);
        assert!(!record.cloned);
        let written = serde_json::to_value(&record).unwrap();
        assert!(written.get("cloned").is_none() && written.get("host_fingerprint").is_none());
    }

    #[test]
    fn a_join_grants_the_same_person_and_keeps_the_owners_own_entries() {
        use crate::mesh_http::{MeshControlFrom, MeshRelayConfig};
        assert_eq!(super::joined_control_from(None), vec![MeshControlFrom::same_user()]);
        let own = MeshControlFrom {
            daemon_id: "d1".into(),
            ops: vec!["stop".into()],
            ..Default::default()
        };
        let previous = MeshRelayConfig { control_from: vec![own.clone()], ..Default::default() };
        assert_eq!(
            super::joined_control_from(Some(previous)),
            vec![own, MeshControlFrom::same_user()]
        );
        // An owner who narrowed or emptied `sameUser` keeps that choice across a rejoin.
        let narrowed = MeshControlFrom { ops: vec![], ..MeshControlFrom::same_user() };
        let previous =
            MeshRelayConfig { control_from: vec![narrowed.clone()], ..Default::default() };
        assert_eq!(super::joined_control_from(Some(previous)), vec![narrowed]);
        // The entry an older join wrote (no `maxPolicy`) becomes today's; one with a cap the
        // owner chose keeps it.
        let unmarked = MeshControlFrom { max_policy: None, ..MeshControlFrom::same_user() };
        let previous = MeshRelayConfig { control_from: vec![unmarked], ..Default::default() };
        assert_eq!(super::joined_control_from(Some(previous)), vec![MeshControlFrom::same_user()]);
        let capped = MeshControlFrom {
            max_policy: Some(crate::config::PermissionPolicy::Ask),
            ..MeshControlFrom::same_user()
        };
        let previous = MeshRelayConfig { control_from: vec![capped.clone()], ..Default::default() };
        assert_eq!(super::joined_control_from(Some(previous)), vec![capped]);
    }

    /// Harness for the write loop: an idle joined daemon heartbeats every 10 s; count the
    /// rewrites of `machine-credential.json` (a new inode per atomic replace) over 10 minutes.
    #[test]
    #[cfg(unix)] // counts inodes
    #[cfg(unix)]
    fn ten_idle_minutes_of_heartbeats_rewrite_the_credential_twenty_times_not_sixty() {
        use std::os::unix::fs::MetadataExt as _;
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let record = super::MachineCredential {
            credential: "cmm_live".into(),
            machine_id: "m".into(),
            ..Default::default()
        };
        super::save_at(home, &record).unwrap();
        let ino = || std::fs::metadata(home.join(super::CREDENTIAL_FILE)).unwrap().ino();
        let start = 1_800_000_000_000u64;
        let (mut last, mut writes) = (ino(), 0);
        for beat in 0..60u64 {
            super::record_auth_result_at(home, "cmm_live", false, true, start + beat * 10_000)
                .unwrap();
            let now = ino();
            if now != last {
                writes += 1;
                last = now;
            }
        }
        eprintln!("credential rewrites in 60 heartbeats (10 min): {writes}");
        assert_eq!(writes, 20);
        // Another credential's answer and a repeated revoke write nothing; the first revoke does.
        super::record_auth_result_at(home, "cmm_old", true, true, start + 700_000).unwrap();
        assert_eq!(ino(), last);
        super::record_auth_result_at(home, "cmm_live", true, false, start + 700_000).unwrap();
        let revoked = ino();
        assert_ne!(revoked, last);
        super::record_auth_result_at(home, "cmm_live", true, false, start + 710_000).unwrap();
        assert_eq!(ino(), revoked);
        assert!(super::load_at(home).unwrap().unwrap().revoked);
    }

    #[test]
    fn a_heartbeat_rewrites_the_credential_only_once_the_stored_one_ages() {
        let at = |ms: Option<u64>| super::MachineCredential {
            last_heartbeat: ms.map(|ms| ms.to_string()),
            ..Default::default()
        };
        let now = 10_000_000;
        assert!(!super::heartbeat_fresh(&at(None), now));
        assert!(super::heartbeat_fresh(&at(Some(now - 10_000)), now));
        assert!(!super::heartbeat_fresh(&at(Some(now - super::HEARTBEAT_PERSIST_MS)), now));
        // A clock that stepped back never pins an old heartbeat as fresh.
        assert!(!super::heartbeat_fresh(&at(Some(now + 5_000)), now));
        const {
            assert!(
                super::HEARTBEAT_PERSIST_MS * 2 < crate::cli::host_join_doctor::HEARTBEAT_WITHIN_MS
            );
        }
    }

    #[test]
    fn an_older_record_reads_with_no_person_and_a_new_one_keeps_it() {
        let old = serde_json::json!({"credential":"cmm_x","machine_id":"m","team_id":"t","name":"n",
            "hub_origin":"https://example.com","last_heartbeat":null,"revoked":false,"wgPublicKey":"k"});
        let record: super::MachineCredential = serde_json::from_value(old).unwrap();
        assert_eq!(record.user_id, None);
        let record = super::MachineCredential { user_id: Some("user_1".into()), ..record };
        let round: super::MachineCredential =
            serde_json::from_value(serde_json::to_value(&record).unwrap()).unwrap();
        assert_eq!(round.user_id.as_deref(), Some("user_1"));
        assert_eq!(super::safe_id("user_1").as_deref(), Some("user_1"));
        for bad in ["", "cmm_secret", "a\nb"] {
            assert_eq!(super::safe_id(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn identity_projection_drops_the_bearer_credential() {
        let record = MachineCredential {
            credential: "do-not-leak-secret-value".into(),
            machine_id: "machine-1".into(),
            team_id: "team-1".into(),
            name: "cloud-machine".into(),
            hub_origin: "https://cmux.example".into(),
            last_heartbeat: None,
            revoked: false,
            wg_public_key: "public-key".into(),
            credential_generation: 1,
            user_id: None,
            host_fingerprint: None,
            cloned: false,
            joined_by: None,
            capabilities: None,
            cloned_on: None,
            named: false,
        };
        let identity = MachineIdentity::from_record(&record);
        let serialized = serde_json::to_string(&identity).unwrap();
        assert!(!serialized.contains(&record.credential));
        assert!(serialized.contains("machine-1"));
    }

    #[test]
    #[cfg(unix)]
    fn concurrent_join_is_refused_before_a_second_redeem() {
        let dir = tempfile::tempdir().unwrap();
        let first = super::join_lock_at(dir.path()).unwrap();
        assert!(super::join_lock_at(dir.path()).is_err());
        // A process spawned meanwhile holds a copy from its fork until its exec.
        let inherited = first.0.try_clone().unwrap();
        drop(first);
        assert!(super::join_lock_at(dir.path()).is_ok());
        drop(inherited);
    }
}
