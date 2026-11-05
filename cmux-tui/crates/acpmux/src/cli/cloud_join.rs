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

/// Whether `record` was copied here from another box: marked so, or joined on a box whose
/// fingerprint differs from this one's. A record or a box with no fingerprint is no clone.
fn copied_here(record: &MachineCredential, current: Option<&str>) -> bool {
    record.cloned
        || matches!((record.host_fingerprint.as_deref(), current), (Some(joined), Some(here)) if joined != here)
}

/// At daemon start, before the WireGuard transport and the mesh relay: a record joined on
/// another box is marked `cloned` and this box gets a fresh `node.wg.key`, so it never answers
/// with the original's credential or key. The hub is not called: the original box's credential
/// stays as it is. An older record with no fingerprint adopts this box's.
pub(crate) fn settle_clone_at_start() -> Result<CloneCheck> {
    let home = state_dir();
    if load_at(&home)?.is_none() {
        return Ok(CloneCheck::NotJoined);
    }
    let _lock = join_lock()?;
    settle_clone_at(&home, host_fingerprint::current().as_deref())
}

/// [`settle_clone_at_start`] in `home`, as the box whose fingerprint is `current`. The caller
/// holds the join lock.
pub(crate) fn settle_clone_at(home: &std::path::Path, current: Option<&str>) -> Result<CloneCheck> {
    let Some(mut record) = load_at(home)? else { return Ok(CloneCheck::NotJoined) };
    if record.cloned {
        return Ok(CloneCheck::AlreadyCloned);
    }
    let Some(current) = current else { return Ok(CloneCheck::Unknown) };
    match record.host_fingerprint.as_deref() {
        Some(joined) if joined == current => Ok(CloneCheck::Same),
        None => {
            record.host_fingerprint = Some(current.to_owned());
            save_at(home, &record)?;
            Ok(CloneCheck::Adopted)
        }
        Some(_) => {
            // The key first: a start cut short before the mark finds the mismatch again and
            // replaces the key once more, never keeps the original's key under a cloned mark.
            crate::cli::mesh_node_key::replace_at(home)?;
            record.cloned = true;
            save_at(home, &record)?;
            Ok(CloneCheck::Cloned)
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
    Ok(load()?.filter(|record| !copied_here(record, current.as_deref())))
}

/// The person this machine recorded at join, for `controlFrom`'s `sameUser` entry. None when
/// the machine is not joined, is revoked, or recorded no person.
pub(crate) fn machine_user_id() -> Option<String> {
    let record = load().ok().flatten()?;
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
        !copied_here(&record, host_fingerprint::current().as_deref()),
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
        .map(|value| value.is_some_and(|record| !copied_here(&record, current.as_deref())))
        .map_err(|_| store_error().into())
}

pub(crate) fn already_joined(replace: bool, json_out: bool) -> Result<bool> {
    let Some(record) = load().map_err(|_| store_error())? else { return Ok(false) };
    // A copy of another box's join is no join of this one: the new join line makes one.
    if replace || join_incomplete()? || copied_here(&record, host_fingerprint::current().as_deref())
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

pub async fn status(hub: Option<String>, json_out: bool) -> Result<()> {
    let pending_origin = recovery::pending_origin()?;
    let fallback_hub = pending_origin.clone().unwrap_or(origin(hub)?);
    if load()?.is_some() {
        // The daemon checks at its start; a status on a box whose daemon has not started since
        // the copy finds it too.
        let _ = settle_clone_at_start();
    }
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
    let mut out = json!({"credentialPresent": !record.credential.is_empty(), "machineId": record.machine_id, "teamId": record.team_id, "hubOrigin": record.hub_origin, "hubReachable": false, "lastHeartbeat": record.last_heartbeat, "revoked": record.revoked, "wgPublicKey": record.wg_public_key, "consent": load_consent(), "credentialStore":"file", "credentialPath":credential_path(), "credentialMode":if record.credential.is_empty() { None } else { Some("0600") }, "daemonRunning":running, "meshRelayConfigured":mesh_relay_configured(), "userId": record.user_id, "build": crate::hub::build(), "channel":null});
    out["joinIncomplete"] = json!(pending_origin.is_some());
    // The copy's own answer: its credential is the original box's and is never sent from here.
    let cloned = copied_here(&record, host_fingerprint::current().as_deref());
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
    use super::{origin, parse_token_text};

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
        assert!(!record.cloned && !super::copied_here(&record, Some("box-a")));
        assert_eq!(std::fs::read(home.path().join("node.wg.key")).unwrap(), key);
    }

    #[test]
    #[cfg(unix)]
    fn a_copied_home_is_marked_cloned_with_a_fresh_key_and_the_credential_left_as_it_was() {
        let home = tempfile::tempdir().unwrap();
        let key = joined_on(home.path(), Some("box-a"));
        let before = super::load_at(home.path()).unwrap().unwrap();
        assert!(
            super::copied_here(&before, Some("box-b")),
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
        assert!(super::copied_here(&record, Some("box-b")) && super::copied_here(&record, None));
    }

    #[test]
    #[cfg(unix)]
    fn an_older_record_adopts_the_box_it_starts_on_and_no_identity_compares_nothing() {
        let home = tempfile::tempdir().unwrap();
        let key = joined_on(home.path(), None);
        let before = super::load_at(home.path()).unwrap().unwrap();
        assert!(!super::copied_here(&before, Some("box-a")), "no fingerprint is no clone");
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
