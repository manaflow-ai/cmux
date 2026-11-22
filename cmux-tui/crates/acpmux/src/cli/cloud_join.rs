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
#[cfg(test)]
use crate::machine_record::home_copy_state;
pub(super) use crate::machine_record::load_at;
pub use crate::machine_record::{
    CONSENT_REQUIRED, Consent, ConsentState, MachineCredential, SIGNED_IN_MACHINES,
    require_consent, require_joined_consent, signed_in_machines_granted,
};
use crate::machine_record::{
    CREDENTIAL_FILE, CopyState, authority, consent_home, copied_here, copy_state, load, other_box,
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
        .or_else(|| std::env::var("CMUX_PLATFORM_ORIGIN").ok())
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
    Ok(parsed.origin().ascii_serialization())
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
    let control_from = joined_control_from(previous);
    config.mesh_relay = Some(crate::mesh_http::MeshRelayConfig {
        url: hub.to_owned(),
        token_command: Vec::new(),
        credential: Some("join".to_owned()),
        team_messaging,
        control_from,
    });
    config.save_with_writer(|path, bytes| recovery::write_durable(path, bytes, true))
}

/// Adds the `sameUser` entry to a joined `meshRelay` that has none. True when it changed
/// config.json. A relay that is not the join's, or none, is left alone.
fn add_same_user_control() -> Result<bool> {
    let _lock = join_lock()?;
    let mut config = crate::config::Config::load()?;
    let Some(relay) = config.mesh_relay.as_mut() else { return Ok(false) };
    if relay.credential.as_deref() != Some("join")
        || relay.control_from.iter().any(|entry| entry.same_user)
    {
        return Ok(false);
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
    recovery::join(hub, name, replace, Report::from_json(json_out), token, None).await
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
    let _lock = join_lock()?;
    if let Some(mut record) = load()? {
        if record.credential != token {
            return Ok(());
        }
        if revoked {
            record.revoked = true;
        }
        if heartbeat {
            record.last_heartbeat = Some(crate::store::now_ms().to_string());
        }
        save(&record)?;
    }
    Ok(())
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

/// This machine's consent and the account it is joined as, read now (blocking file reads).
pub fn signed_in_machines_granted_here() -> (bool, Option<String>) {
    let account = machine_user_id();
    let granted = signed_in_machines_granted(&consent_status_for(&json!({})), account.as_deref());
    (granted, account)
}

/// `_acpmux/machine_consent_get`'s answer. With `{"use": "localComputerUse"}` (the app asking
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
    reqwest::Client::builder()
        .default_headers(cmux_build_space::headers()?)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .context("build hub client")
}

#[cfg(test)]
#[path = "cloud_join_tests.rs"]
mod tests;
