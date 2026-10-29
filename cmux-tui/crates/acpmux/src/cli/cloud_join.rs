//! Cloud machine onboarding. The join secret is read from stdin and is never
//! placed in argv, the environment, a URL, or a diagnostic message.

use anyhow::{Context, Result, anyhow};
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::PathBuf;

pub const CAPABILITY: &str = "machine.join.stdin.v1";
pub const DEFAULT_HUB: &str = "https://cmux-platform-development.debussy.workers.dev";
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

#[derive(Clone, Serialize, Deserialize)]
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
        || token[4..].bytes().any(|b| !(b.is_ascii_alphanumeric() || b == b'_' || b == b'-'))
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
    crate::config::private_state_dir(&state_dir())?;
    crate::config::write_atomic(&credential_path(), &serde_json::to_vec_pretty(record)?)
}

fn configure_mesh_relay(hub: &str) -> Result<()> {
    let mut config = crate::config::Config::load()?;
    config.mesh_relay = Some(crate::mesh_http::MeshRelayConfig {
        url: hub.to_owned(),
        token_command: Vec::new(),
        credential: Some("join".to_owned()),
    });
    config.save()
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
        origin(Some(record.hub_origin.clone()))? == origin(Some(hub_origin.to_owned()))?,
        "machine credential belongs to another hub"
    );
    anyhow::ensure!(record.credential.starts_with("cmm_"), "machine credential is malformed");
    Ok(record.credential)
}

fn authority() -> Result<super::machine_consent::Authority> {
    super::machine_consent::Authority::current(consent_home())
}

pub(crate) fn retain_own_machine_consent_requirement() -> Result<()> {
    authority()?.retain_own_requirement()
}

fn load_consent() -> Consent {
    serde_json::from_value(consent_status()["consent"].clone()).unwrap_or_default()
}

/// Held until redeem and both local writes complete. A competing installer exits
/// without redeeming; it can safely retry after this process finishes.
#[cfg(unix)]
pub(crate) fn join_lock() -> Result<std::fs::File> {
    crate::config::private_state_dir(&state_dir())?;
    join_lock_at(&state_dir())
}

#[cfg(unix)]
fn join_lock_at(dir: &std::path::Path) -> Result<std::fs::File> {
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
    Ok(file)
}

#[cfg(not(unix))]
pub(crate) fn join_lock() -> Result<std::fs::File> {
    anyhow::bail!("machine join requires macOS or Linux")
}

pub(crate) fn credential_present() -> Result<bool> {
    load().map(|value| value.is_some()).map_err(|_| store_error().into())
}

pub(crate) fn already_joined(replace: bool, json_out: bool) -> Result<bool> {
    let Some(record) = load().map_err(|_| store_error())? else { return Ok(false) };
    if replace {
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
    token: String,
) -> Result<()> {
    if already_joined(replace, json_out)? {
        return Ok(());
    }
    let hub = origin(hub).map_err(|_| {
        crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Usage,
            "join.malformed",
            "hub origin is malformed",
        )
        .with_exit(2)
    })?;
    let name = local_name(name);
    if name.is_empty() || name.len() > 63 || name.chars().any(char::is_control) {
        return Err(crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Usage,
            "join.malformed",
            "machine name must contain 1 to 63 non-control bytes",
        )
        .with_exit(2)
        .into());
    }
    let hostname = crate::pairing::machine_name();
    let wg_public_key = crate::cli::mesh_node_key::load_or_create()
        .map_err(|_| {
            crate::cli::errors::AppError::new(
                crate::cli::errors::Code::Runtime,
                "join.store",
                "node key unavailable",
            )
            .with_exit(5)
        })?
        .public_key_b64();
    let platform = if cfg!(target_os = "macos") { "macos" } else { "linux" };
    authority().and_then(|authority| authority.enroll()).map_err(|_| store_error())?;
    let response = http_client().map_err(|_| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.hub", "hub unreachable").with_exit(4))?.post(format!("{hub}/v1/machines/join-tokens/redeem"))
        .json(&json!({"token": token, "platform": platform, "hostname": hostname, "name": name, "wgPublicKey": wg_public_key}))
        .send().await.map_err(|_| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.hub", "hub unreachable").with_exit(4))?;
    let status = response.status();
    let body: Value = response.json().await.unwrap_or_else(|_| json!({}));
    if !status.is_success() {
        let code = body.get("code").and_then(Value::as_str).unwrap_or_default();
        let exit = if matches!(status.as_u16(), 404 | 409 | 410)
            || matches!(code, "join.expired" | "join.used" | "join.malformed")
        {
            3
        } else {
            4
        };
        let safe_code = match code {
            "join.expired" => "join.expired",
            "join.used" => "join.used",
            "join.malformed" => "join.malformed",
            _ => "join.failed",
        };
        return Err(crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Runtime,
            safe_code,
            "machine join failed",
        )
        .with_exit(exit)
        .into());
    }
    let credential = body.get("credential").and_then(Value::as_str).ok_or_else(|| {
        crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Runtime,
            "join.hub",
            "hub returned an invalid response",
        )
        .with_exit(4)
    })?;
    if !credential.starts_with("cmm_")
        || credential[4..].is_empty()
        || credential[4..].bytes().any(|b| !(b.is_ascii_alphanumeric() || b == b'_' || b == b'-'))
    {
        return Err(crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Runtime,
            "join.hub",
            "hub returned an invalid response",
        )
        .with_exit(4)
        .into());
    }
    let machine_id = body.get("machineId").and_then(Value::as_str).ok_or_else(|| {
        crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Runtime,
            "join.hub",
            "hub returned an invalid response",
        )
        .with_exit(4)
    })?;
    let team_id = body.get("teamId").and_then(Value::as_str).ok_or_else(|| {
        crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Runtime,
            "join.hub",
            "hub returned an invalid response",
        )
        .with_exit(4)
    })?;
    if machine_id.is_empty()
        || team_id.is_empty()
        || machine_id.contains("cmj_")
        || machine_id.contains("cmm_")
        || team_id.contains("cmj_")
        || team_id.contains("cmm_")
    {
        return Err(crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Runtime,
            "join.hub",
            "hub returned an invalid response",
        )
        .with_exit(4)
        .into());
    }
    let returned_key = body.get("wgPublicKey").and_then(Value::as_str).unwrap_or(&wg_public_key);
    let key_ok = returned_key == wg_public_key
        && returned_key.len() == 44
        && returned_key.ends_with('=')
        && base64::engine::general_purpose::STANDARD
            .decode(returned_key)
            .map(|bytes| bytes.len() == 32)
            .unwrap_or(false);
    if !key_ok {
        return Err(crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Runtime,
            "join.hub",
            "hub returned an invalid response",
        )
        .with_exit(4)
        .into());
    }
    let record = MachineCredential {
        credential: credential.to_owned(),
        machine_id: machine_id.to_owned(),
        team_id: team_id.to_owned(),
        name,
        hub_origin: hub.clone(),
        last_heartbeat: None,
        revoked: false,
        wg_public_key: returned_key.to_owned(),
    };
    save(&record).map_err(|_| {
        crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Runtime,
            "join.store",
            "join token was used but the credential could not be saved; fix local storage, revoke this machine in the machine list, then run machine add again for a fresh token",
        )
        .with_exit(5)
    })?;
    configure_mesh_relay(&hub).map_err(|_e| {
        crate::cli::errors::AppError::new(
            crate::cli::errors::Code::Runtime,
            "join.store",
            "mesh relay configuration failed",
        )
        .with_exit(5)
    })?;
    eprintln!(
        "Existing Computer Use helpers may remain ungated until they exit; close them normally and use updated builds before enabling remote access."
    );
    if json_out {
        crate::cli::output::print_json(
            &json!({"joined":true,"alreadyJoined":false,"machineId":record.machine_id,"teamId":record.team_id,"name":record.name,"hubOrigin":hub}),
        );
    } else {
        println!("joined {} ({})", record.name, record.machine_id);
    }
    Ok(())
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
    let fallback_hub = origin(hub)?;
    let record = load()?.unwrap_or(MachineCredential {
        credential: String::new(),
        machine_id: String::new(),
        team_id: String::new(),
        name: local_name(None),
        hub_origin: fallback_hub,
        last_heartbeat: None,
        revoked: false,
        wg_public_key: String::new(),
    });
    let daemon = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        crate::client::Client::connect(&crate::config::socket_path()),
    )
    .await;
    let running = matches!(daemon, Ok(Ok(_)));
    let mut out = json!({"credentialPresent": !record.credential.is_empty(), "machineId": record.machine_id, "teamId": record.team_id, "hubOrigin": record.hub_origin, "hubReachable": false, "lastHeartbeat": record.last_heartbeat, "revoked": record.revoked, "wgPublicKey": record.wg_public_key, "consent": load_consent(), "credentialStore":"file", "credentialPath":credential_path(), "credentialMode":if record.credential.is_empty() { None } else { Some("0600") }, "daemonRunning":running, "meshRelayConfigured":mesh_relay_configured(), "build": crate::hub::BUILD, "channel":null});
    out["helperConsent"] =
        json!({"state":"unknown","reason":"running helper consent support has not been verified"});
    out["lastRefusal"] = consent_status()["lastRefusal"].clone();
    if !record.credential.is_empty() {
        // GET is read-only: doctor must never replace the daemon's live sessions.
        if let Ok(res) = http_client()?
            .get(format!("{}/v1/mesh/sessions", origin(Some(record.hub_origin.clone()))?))
            .bearer_auth(&record.credential)
            .send()
            .await
        {
            out["hubReachable"] = json!(true);
            if res.status().as_u16() == 401 {
                record_auth_result(&record.credential, true, false)?;
                out["revoked"] = json!(true);
            }
        }
    }
    if json_out {
        crate::cli::output::print_json(&out);
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

fn http_client() -> Result<reqwest::Client> {
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

    #[test]
    #[cfg(unix)]
    fn concurrent_join_is_refused_before_a_second_redeem() {
        let dir = tempfile::tempdir().unwrap();
        let first = super::join_lock_at(dir.path()).unwrap();
        assert!(super::join_lock_at(dir.path()).is_err());
        drop(first);
        assert!(super::join_lock_at(dir.path()).is_ok());
    }
}
