//! Cloud machine onboarding. The join secret is read from stdin and is never
//! placed in argv, the environment, a URL, or a diagnostic message.

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::PathBuf;

pub(crate) mod host_fingerprint;
mod leave;
mod recovery;

pub const CAPABILITY: &str = "machine.join.stdin.v1";
/// The hub a join with no `--hub` uses: cmux-platform's production origin
/// (Leo, 2026-11-04: "If I tell you to do something, don't stick it into
/// dev. Put it into prod."). `--hub` still names another one.
pub const DEFAULT_HUB: &str = cmux_cloud_client::backend::Backend::Production.platform();
pub const CONSENT_REQUIRED: &str = "consent_required";
const MAX_TOKEN_BYTES: usize = 512;
const CREDENTIAL_FILE: &str = "machine-credential.json";
static CONSENT_HOME: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

/// A hand later switches config::home to its private agent daemon. Consent
/// continues to belong to the physical machine's original enrolled state.
pub(crate) fn retain_machine_consent_home() {
    let _ = CONSENT_HOME.set(crate::config::home());
}

fn consent_home() -> PathBuf {
    CONSENT_HOME.get().cloned().unwrap_or_else(state_dir)
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct MachineCredential {
    pub credential: String,
    pub machine_id: String,
    pub team_id: String,
    pub name: String,
    pub hub_origin: String,
    pub last_heartbeat: Option<String>,
    pub revoked: bool,
    #[serde(rename = "wgPublicKey")]
    pub wg_public_key: String,
    #[serde(default)]
    pub credential_generation: u64,
    /// The person who enrolled this machine, from the hub's answer for this credential
    /// (`userId`). `meshRelay.controlFrom`'s `sameUser` entry matches it against the
    /// hub-stamped sender. None (an older join, or a hub that does not name it yet) grants
    /// nothing automatically.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_id: Option<String>,
    /// The box this credential was joined on (`host_fingerprint`). None on a record joined
    /// before it existed: the first daemon start adopts the box it runs on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_fingerprint: Option<String>,
    /// This record was copied here from the box that joined it. The credential is never used
    /// here again (it stays the original box's, untouched on the hub); a new join line gives
    /// this box its own.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cloned: bool,
    /// The box that found this record copied and gave itself a fresh node key (its
    /// `host_fingerprint`). A `cloned` record on any other box is a copy of that copy, its node
    /// key the settling box's: found and settled again. None on a record settled before it
    /// existed: the next start on the box it runs on takes it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cloned_on: Option<String>,
}

/// A hub-supplied id the store keeps: non-empty, one line, and no secret-shaped text.
pub(crate) fn safe_id(value: &str) -> Option<String> {
    Some(value)
        .filter(|s| {
            !s.is_empty()
                && s.len() <= 256
                && !s.contains("cmj_")
                && !s.contains("cmm_")
                && !s.chars().any(char::is_control)
        })
        .map(str::to_owned)
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

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Consent {
    pub screen: ConsentState,
    pub control: ConsentState,
    #[serde(rename = "grantedAt", skip_serializing_if = "Option::is_none")]
    pub granted_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ConsentState {
    #[default]
    None,
    Granted,
}

fn state_dir() -> PathBuf {
    crate::config::home()
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
    name.unwrap_or_else(crate::pairing::machine_name)
}

fn save(record: &MachineCredential) -> Result<()> {
    save_at(&state_dir(), record)
}

fn save_at(home: &std::path::Path, record: &MachineCredential) -> Result<()> {
    crate::config::private_state_dir(home)?;
    recovery::write_durable(&home.join(CREDENTIAL_FILE), &serde_json::to_vec_pretty(record)?, true)
}

/// What `record`, read from `home`, is to the box whose fingerprint is `current`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CopyState {
    /// Joined here, or nothing to compare (no fingerprint on the record or this box).
    Own,
    /// Copied from another box and settled on this one: marked `cloned` here, the node key
    /// replaced with this box's own.
    SettledHere,
    /// Copied and not settled here: joined on another box, or marked `cloned` on another box
    /// (a copy of a copy). The node key in `home` is another box's.
    Unsettled,
}

/// Whether `stamp`, a box fingerprint recorded in `home`, names another box than `current`. A
/// missing stamp or a box with no fingerprint compares nothing.
fn other_box(home: &std::path::Path, stamp: Option<&str>, current: Option<&str>) -> bool {
    matches!((stamp, current), (Some(then), Some(here)) if !host_fingerprint::same_box(home, then, here))
}

fn copy_state(
    home: &std::path::Path,
    record: &MachineCredential,
    current: Option<&str>,
) -> CopyState {
    if record.cloned {
        if other_box(home, record.cloned_on.as_deref(), current) {
            CopyState::Unsettled
        } else {
            CopyState::SettledHere
        }
    } else if other_box(home, record.host_fingerprint.as_deref(), current) {
        CopyState::Unsettled
    } else {
        CopyState::Own
    }
}

/// The one "was this home copied here" predicate, from every piece of evidence a home holds
/// about the box it was made on: its machine record (`record`, the one on disk or the one a
/// caller is about to replace) and a join begun there and not finished
/// (`machine-join.pending.json`, [`recovery::pending_made_on`]). A pending join proposed on
/// another box makes the home a copy not settled here, whatever the record says: the node key
/// beside it is that box's. Every caller that decides "copied home" goes through it
/// ([`copied_here`], [`copied_at`], [`node_key_copied_at`], `host join`'s set-aside).
fn home_copy_state(
    home: &std::path::Path,
    record: Option<&MachineCredential>,
    current: Option<&str>,
) -> CopyState {
    let by_record = record.map_or(CopyState::Own, |record| copy_state(home, record, current));
    if by_record != CopyState::Unsettled
        && recovery::pending_made_on(home)
            .is_some_and(|made| other_box(home, made.as_deref(), current))
    {
        return CopyState::Unsettled;
    }
    by_record
}

/// [`home_copy_state`], recording a copy not settled here (`mesh_node_key::record_copied_key`)
/// before it answers.
///
/// The key recorded is the one read before the evidence that shows the copy, never the one in
/// place when it is recorded: a settle saves the settled record before it replaces the key
/// ([`settle_clone_at`]), so a record still unsettled when read again after the key means that
/// key is the copy's. A `host join` or a settled start may replace it meanwhile with this box's
/// own (registered) key, which is never marked.
fn settle_evidence(
    home: &std::path::Path,
    record: Option<&MachineCredential>,
    current: Option<&str>,
) -> CopyState {
    let key = crate::cli::mesh_node_key::public_key_at(home);
    let state = home_copy_state(home, record, current);
    if state != CopyState::Unsettled {
        return state;
    }
    // Asked again after the key: the record the caller read may predate a settle (and a
    // join) since; one a leave removed meanwhile leaves the caller's.
    let again = load_at(home).ok().flatten();
    if let Some(key) = key
        && home_copy_state(home, again.as_ref().or(record), current) == CopyState::Unsettled
        && let Err(e) = crate::cli::mesh_node_key::record_copied_public_key(home, &key)
    {
        tracing::warn!("could not record the copied node key: {e:#}");
    }
    state
}

/// Whether `record`, read from `home`, was copied here from another box: marked so, or joined
/// (or settled) on a box whose fingerprint differs from this one's. A record or a box with no
/// fingerprint is no clone.
///
/// A copy found here and not settled here yet ([`CopyState::Unsettled`]) is recorded first,
/// durably, whatever the caller does next: the node key now in `home` is another box's
/// (`mesh_node_key::record_copied_key`, which keeps every key it was ever told). A `machine
/// leave` may delete this record right after, and the key may stay (the cmux link adopted
/// it); the record keeps every later holder, the link included, from serving that key here.
fn copied_here(home: &std::path::Path, record: &MachineCredential, current: Option<&str>) -> bool {
    settle_evidence(home, Some(record), current) != CopyState::Own
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

/// Whether the node key now in acpmux home `home` is another box's: its record is a copy not
/// settled here (found live, and recorded), or the key is one recorded as copied
/// (`mesh_node_key::serves_copied_key`, which outlives the record). A home settled here (its
/// own fresh key) is not. What the cmux link asks before it adopts or serves the key.
pub(crate) fn node_key_copied_at(home: &std::path::Path) -> bool {
    let current = host_fingerprint::current();
    let record = load_at(home).ok().flatten();
    settle_evidence(home, record.as_ref(), current.as_deref()) == CopyState::Unsettled
        || crate::cli::mesh_node_key::serves_copied_key(home)
}

/// Whether the node key in acpmux home `home` is provably this box's own
/// (`mesh_node_key::node_key_own_here`): the record is live and joined or settled on this
/// box, nothing shows a copy, and the key is not one recorded as copied.
pub(crate) fn node_key_own_at(home: &std::path::Path) -> bool {
    let current = host_fingerprint::current();
    let Some(record) = load_at(home).ok().flatten() else { return false };
    !record.revoked
        && home_copy_state(home, Some(&record), current.as_deref()) != CopyState::Unsettled
        && !crate::cli::mesh_node_key::serves_copied_key(home)
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

fn configure_mesh_relay(hub: &str) -> Result<()> {
    let mut config = crate::config::Config::load()?;
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

fn load() -> Result<Option<MachineCredential>> {
    load_at(&state_dir())
}

/// The joined machine credential, for the vault pull (`crate::vault`), which
/// sends it only as the bearer of its own hub request.
///
/// A record copied from another box is no credential of this one: None, as if not joined.
pub(crate) fn machine_credential() -> Result<Option<MachineCredential>> {
    let current = host_fingerprint::current();
    Ok(load()?.filter(|record| !copied_here(&state_dir(), record, current.as_deref())))
}

/// The person this machine recorded at join, for `controlFrom`'s `sameUser` entry. None when
/// the machine is not joined, is revoked, or recorded no person.
pub(crate) fn machine_user_id() -> Option<String> {
    // A copy of another box's join speaks for nobody here.
    let record = machine_credential().ok().flatten()?;
    (!record.revoked).then_some(record.user_id?).and_then(|user| safe_id(&user))
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

pub(super) fn load_at(home: &std::path::Path) -> Result<Option<MachineCredential>> {
    let path = home.join(CREDENTIAL_FILE);
    match std::fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
        Ok(_) => {}
    }
    let file = crate::config::private_state_file(&path)?;
    Ok(Some(serde_json::from_reader(file).context("read machine credential")?))
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

fn authority() -> Result<super::machine_consent::Authority> {
    super::machine_consent::Authority::current(consent_home())
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
#[cfg(unix)]
pub(crate) fn join_lock() -> Result<HeldLock> {
    crate::config::private_state_dir(&state_dir())?;
    join_lock_at(&state_dir())
}

/// [`join_lock`] in acpmux home `home` (made private by the caller).
#[cfg(unix)]
fn join_lock_in(home: &std::path::Path) -> Result<HeldLock> {
    join_lock_at(home)
}

#[cfg(unix)]
fn join_lock_at(dir: &std::path::Path) -> Result<HeldLock> {
    let file = crate::config::private_state_rw(&dir.join("machine-join.lock"))?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        // SAFETY: this process owns the opened regular-file descriptor.
        anyhow::ensure!(
            unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
            "another machine join is in progress; retry when it finishes"
        );
    }
    Ok(HeldLock(file))
}

#[cfg(not(unix))]
pub(crate) fn join_lock() -> Result<HeldLock> {
    anyhow::bail!("machine join requires macOS or Linux")
}

#[cfg(not(unix))]
fn join_lock_in(_: &std::path::Path) -> Result<HeldLock> {
    join_lock()
}

/// A held `flock`. Dropping it unlocks explicitly: a process spawned meanwhile (an agent, a
/// tool, a login shell) shares the lock's open file description from its fork until its exec,
/// so closing this descriptor alone would leave the lock held until then, and the next
/// nonblocking take would fail as if another holder were still at work.
pub(crate) struct HeldLock(pub(super) std::fs::File);

impl Drop for HeldLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

pub(crate) fn credential_present() -> Result<bool> {
    let current = host_fingerprint::current();
    load()
        .map(|value| {
            value.is_some_and(|record| !copied_here(&state_dir(), &record, current.as_deref()))
        })
        .map_err(|_| store_error().into())
}

pub(crate) fn already_joined(replace: bool, json_out: bool) -> Result<bool> {
    let Some(record) = load().map_err(|_| store_error())? else { return Ok(false) };
    // A copy of another box's join is no join of this one: the new join line makes one.
    if replace
        || join_incomplete()?
        || copied_here(&state_dir(), &record, host_fingerprint::current().as_deref())
    {
        return Ok(false);
    }
    // No released build created pre-marker credentials. Even branch-only local
    // state must persist the shared requirement before idempotent success.
    authority().and_then(|authority| authority.enroll()).map_err(|_| store_error())?;
    // Repair a previous config-save failure before reporting idempotent success.
    configure_mesh_relay(&record.hub_origin).map_err(|_| store_error())?;
    warn_existing_helpers();
    if json_out {
        crate::cli::output::print_json(
            &json!({"joined":false,"alreadyJoined":true,"machineId":record.machine_id,"teamId":record.team_id,"name":record.name,"hubOrigin":record.hub_origin}),
        );
    } else {
        println!("already joined ({})", record.machine_id);
    }
    Ok(true)
}

fn warn_existing_helpers() {
    eprintln!(
        "Existing Computer Use helpers may remain ungated until they exit; close them normally and use updated builds before enabling remote access."
    );
}

fn store_error() -> crate::cli::errors::AppError {
    crate::cli::errors::AppError::new(
        crate::cli::errors::Code::Runtime,
        "join.store",
        "local machine store unavailable",
    )
    .with_exit(5)
}

pub async fn join_with_token(
    hub: Option<String>,
    name: Option<String>,
    replace: bool,
    json_out: bool,
    token: Option<String>,
) -> Result<()> {
    recovery::join(hub, name, replace, json_out, token).await
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

/// Only the person-proven local daemon RPC calls this writer. The ordinary
/// CLI deliberately has no person key and cannot grant consent from a PTY.
pub(crate) fn set_consent_for_person(surface: &str, granted: bool) -> Result<Consent> {
    authority()?.set(surface, granted)
}

pub(crate) fn consent_status() -> Value {
    authority().map(|authority| authority.status()).unwrap_or_else(
        |_| json!({"consentRequired":true,"consent":Consent::default(),"lastRefusal":null}),
    )
}

pub fn require_consent(surface: &str) -> Result<()> {
    let status = consent_status();
    if matches!(surface, "screen" | "control") && status["consent"][surface] == "granted" {
        Ok(())
    } else {
        let _ = record_consent_refusal(surface);
        Err(anyhow!(CONSENT_REQUIRED))
    }
}

pub fn require_joined_consent(surface: &str) -> Result<()> {
    if consent_status()["consentRequired"] == false { Ok(()) } else { require_consent(surface) }
}

pub(crate) fn record_consent_refusal(surface: &str) -> Result<()> {
    authority()?.refused(surface)
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
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .context("build hub client")
}

#[cfg(test)]
mod tests {
    use super::{MachineCredential, MachineIdentity, origin, parse_token_text};

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
        let removed = super::leave::remove_local(home.path()).unwrap();
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
            cloned_on: None,
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
