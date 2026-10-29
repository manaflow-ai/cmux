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
const CONSENT_FILE: &str = "consent.json";
const CONSENT_EVENTS_FILE: &str = "consent-events.jsonl";

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
pub enum ConsentState { #[default] None, Granted }

fn state_dir() -> PathBuf { crate::config::home() }
fn credential_path() -> PathBuf { state_dir().join(CREDENTIAL_FILE) }
fn consent_path() -> PathBuf { state_dir().join(CONSENT_FILE) }

pub fn read_token() -> Result<String> {
    let line = crate::cli::join_input::read_stdin_line()?;
    parse_token_text(&line)
}

pub fn parse_token_text(text: &str) -> Result<String> {
    let token = text.trim();
    if token.is_empty() { return Err(anyhow!("join token is empty")); }
    if !token.starts_with("cmj_") || token.len() > MAX_TOKEN_BYTES
        || token[4..].bytes().any(|b| !(b.is_ascii_alphanumeric() || b == b'_' || b == b'-')) {
        return Err(anyhow!("join token is malformed"));
    }
    Ok(token.to_owned())
}

fn origin(value: Option<String>) -> Result<String> {
    let value = value.or_else(|| std::env::var("CMUX_PLATFORM_ORIGIN").ok()).unwrap_or_else(|| DEFAULT_HUB.to_owned());
    let value = value.trim_end_matches('/').to_owned();
    let parsed = reqwest::Url::parse(&value).map_err(|_| anyhow!("hub origin is malformed"))?;
    anyhow::ensure!(parsed.path() == "/" || parsed.path().is_empty(), "hub origin must not include a path");
    anyhow::ensure!(parsed.query().is_none() && parsed.fragment().is_none(), "hub origin must not include a query");
    anyhow::ensure!(parsed.scheme() == "https" || matches!(parsed.host_str(), Some("localhost") | Some("127.0.0.1") | Some("[::1]")), "hub origin must use https");
    Ok(value)
}

fn local_name(name: Option<String>) -> String {
    name.filter(|v| !v.trim().is_empty()).unwrap_or_else(|| std::process::Command::new("hostname").output().ok().and_then(|v| String::from_utf8(v.stdout).ok()).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty()).unwrap_or_else(|| "cmux-machine".to_owned()))
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
    crate::config::Config::load().ok().and_then(|config| config.mesh_relay).is_some_and(|relay| relay.credential.as_deref() == Some("join"))
}

fn load() -> Result<Option<MachineCredential>> {
    let path = credential_path();
    if !path.exists() { return Ok(None); }
    let file = crate::config::private_state_file(&path)?;
    Ok(Some(serde_json::from_reader(file).context("read machine credential")?))
}

/// The relay client reads the joined bearer in-process from the owner-only store.
/// It never receives a command, URL or environment value containing the credential.
pub(crate) fn read_join_credential() -> Result<String> {
    let record = load()?.ok_or_else(|| anyhow!("machine credential is missing"))?;
    anyhow::ensure!(record.credential.starts_with("cmm_"), "machine credential is malformed");
    Ok(record.credential)
}

fn load_consent() -> Consent {
    let path = consent_path();
    crate::config::private_state_file(&path).ok().and_then(|f| serde_json::from_reader(f).ok()).unwrap_or_default()
}

pub async fn join(hub: Option<String>, name: Option<String>, replace: bool, json_out: bool) -> Result<()> {
    let token = read_token().map_err(|e| crate::cli::errors::AppError::new(crate::cli::errors::Code::Usage, "join.malformed", e.to_string()).with_exit(2))?;
    join_with_token(hub, name, replace, json_out, token).await
}

pub async fn join_with_token(hub: Option<String>, name: Option<String>, replace: bool, json_out: bool, token: String) -> Result<()> {
    let existing = load().map_err(|e| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.store", e.to_string()).with_exit(5))?;
    if let Some(existing) = existing && !replace {
        if json_out { crate::cli::output::print_json(&json!({"joined":false,"alreadyJoined":true,"machineId":existing.machine_id,"teamId":existing.team_id,"name":existing.name,"hubOrigin":existing.hub_origin})); }
        else { println!("already joined ({})", existing.machine_id); }
        return Ok(());
    }
    let hub = origin(hub).map_err(|_| crate::cli::errors::AppError::new(crate::cli::errors::Code::Usage, "join.malformed", "hub origin is malformed").with_exit(2))?;
    let name = local_name(name);
    let wg_public_key = crate::cli::mesh_node_key::load_or_create()
        .map_err(|_| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.store", "node key unavailable").with_exit(5))?
        .public_key_b64();
    let platform = if cfg!(target_os = "macos") { "macos" } else { "linux" };
    let response = http_client().map_err(|_| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.hub", "hub unreachable").with_exit(4))?.post(format!("{hub}/v1/machines/join-tokens/redeem"))
        .json(&json!({"token": token, "platform": platform, "hostname": name, "name": name, "wgPublicKey": wg_public_key}))
        .send().await.map_err(|_| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.hub", "hub unreachable").with_exit(4))?;
    let status = response.status();
    let body: Value = response.json().await.unwrap_or_else(|_| json!({}));
    if !status.is_success() {
        let code = body.get("code").and_then(Value::as_str).unwrap_or_default();
        let exit = if status.as_u16() == 410 || matches!(code, "join.expired" | "join.used" | "join.malformed") { 3 } else if status.as_u16() == 404 { 3 } else { 4 };
        let safe_code = match code { "join.expired" => "join.expired", "join.used" => "join.used", "join.malformed" => "join.malformed", _ => "join.failed" };
        return Err(crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, safe_code, "machine join failed").with_exit(exit).into());
    }
    let credential = body.get("credential").and_then(Value::as_str).ok_or_else(|| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.hub", "hub returned an invalid response").with_exit(4))?;
    if !credential.starts_with("cmm_") || credential[4..].is_empty() || credential[4..].bytes().any(|b| !(b.is_ascii_alphanumeric() || b == b'_' || b == b'-')) {
        return Err(crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.hub", "hub returned an invalid response").with_exit(4).into());
    }
    let machine_id = body.get("machineId").and_then(Value::as_str).ok_or_else(|| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.hub", "hub returned an invalid response").with_exit(4))?;
    let team_id = body.get("teamId").and_then(Value::as_str).ok_or_else(|| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.hub", "hub returned an invalid response").with_exit(4))?;
    let returned_key = body.get("wgPublicKey").and_then(Value::as_str).unwrap_or(&wg_public_key);
    let key_ok = returned_key.len() == 44 && returned_key.ends_with('=') && base64::engine::general_purpose::STANDARD.decode(returned_key).map(|bytes| bytes.len() == 32).unwrap_or(false);
    if !key_ok {
        return Err(crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.hub", "hub returned an invalid response").with_exit(4).into());
    }
    let record = MachineCredential { credential: credential.to_owned(), machine_id: machine_id.to_owned(), team_id: team_id.to_owned(), name, hub_origin: hub.clone(), last_heartbeat: None, revoked: false, wg_public_key: returned_key.to_owned() };
    save(&record).map_err(|e| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.store", e.to_string()).with_exit(5))?;
    configure_mesh_relay(&hub).map_err(|_e| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.store", "mesh relay configuration failed").with_exit(5))?;
    if json_out { crate::cli::output::print_json(&json!({"joined":true,"alreadyJoined":false,"machineId":record.machine_id,"teamId":record.team_id,"name":record.name,"hubOrigin":hub})); }
    else { println!("joined {} ({})", record.name, record.machine_id); }
    Ok(())
}

pub async fn status(hub: Option<String>, json_out: bool) -> Result<()> {
    let fallback_hub = origin(hub)?;
    let record = load()?.unwrap_or(MachineCredential { credential: String::new(), machine_id: String::new(), team_id: String::new(), name: local_name(None), hub_origin: fallback_hub, last_heartbeat: None, revoked: false, wg_public_key: String::new() });
    let mut out = json!({"credentialPresent": !record.credential.is_empty(), "machineId": record.machine_id, "teamId": record.team_id, "hubOrigin": record.hub_origin, "hubReachable": false, "lastHeartbeat": record.last_heartbeat, "revoked": record.revoked, "wgPublicKey": record.wg_public_key, "consent": load_consent(), "credentialStore":"file", "credentialPath":credential_path(), "credentialMode":"0600", "daemonRunning":false, "meshRelayConfigured":mesh_relay_configured(), "build": crate::hub::BUILD, "channel":"feat-cmux-next"});
    if !record.credential.is_empty() {
        if let Ok(res) = http_client()?.post(format!("{}/v1/mesh/heartbeat", record.hub_origin.trim_end_matches('/')))
            .bearer_auth(&record.credential)
            .json(&json!({"host": record.name, "sessions": []}))
            .send().await {
            out["hubReachable"] = json!(res.status().is_success() || res.status().as_u16() == 401);
            if res.status().as_u16() == 401 {
                out["revoked"] = json!(true);
            } else if res.status().is_success() {
                let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs();
                out["lastHeartbeat"] = json!(now.to_string());
            }
        }
    }
    if json_out { crate::cli::output::print_json(&out); } else if out["revoked"] == true { println!("revoked: run machine add again"); } else { println!("credential: {}\nhub: {}\nlast heartbeat: {}", if out["credentialPresent"] == true { "present" } else { "missing" }, if out["hubReachable"] == true { "reachable" } else { "unreachable" }, out["lastHeartbeat"].as_str().unwrap_or("never")); }
    Ok(())
}

pub fn grant_consent(surface: &str) -> Result<()> {
    confirm_local_person("Grant", surface)?;
    let mut consent = load_consent();
    let now = format!("{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs());
    match surface { "screen" => consent.screen = ConsentState::Granted, "control" => consent.control = ConsentState::Granted, _ => return Err(anyhow!("use --screen or --control")) }
    consent.granted_at = Some(now);
    crate::config::private_state_dir(&state_dir())?;
    crate::config::write_atomic(&consent_path(), &serde_json::to_vec_pretty(&consent)?)
}

pub fn revoke_consent(surface: &str) -> Result<()> {
    confirm_local_person("Revoke", surface)?;
    let mut consent = load_consent();
    match surface { "screen" => consent.screen = ConsentState::None, "control" => consent.control = ConsentState::None, _ => return Err(anyhow!("use --screen or --control")) }
    crate::config::private_state_dir(&state_dir())?;
    crate::config::write_atomic(&consent_path(), &serde_json::to_vec_pretty(&consent)?)
}

fn confirm_local_person(action: &str, surface: &str) -> Result<()> {
    if !std::io::stdin().is_terminal() || std::env::var_os("ACPMUX_SESSION_ID").is_some() {
        return Err(anyhow!("consent requires the local person's terminal"));
    }
    eprint!("{action} {surface} consent on this machine? Type 'yes' to continue: ");
    use std::io::Write;
    std::io::stderr().flush()?;
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer)?;
    anyhow::ensure!(answer.trim() == "yes", "consent not granted");
    Ok(())
}

pub fn require_consent(surface: &str) -> Result<()> {
    let consent = load_consent();
    let granted = match surface { "screen" => matches!(consent.screen, ConsentState::Granted), "control" => matches!(consent.control, ConsentState::Granted), _ => false };
    if granted { Ok(()) } else {
        let _ = record_consent_refusal(surface);
        Err(anyhow!(CONSENT_REQUIRED))
    }
}

/// Computer Use and other host-control surfaces call this before serving a
/// joined machine. Unjoined local daemons retain their existing app behavior.
pub fn require_joined_consent(surface: &str) -> Result<()> {
    match load() {
        Ok(Some(_)) => require_consent(surface),
        Ok(None) => Ok(()),
        Err(_) => Err(anyhow!(CONSENT_REQUIRED)),
    }
}

/// Record a local refusal for the app's one-time consent sheet. The file is
/// owner-only and is intentionally separate from the grant record so a mesh
/// caller cannot turn a refusal into a grant by editing one JSON object.
fn record_consent_refusal(surface: &str) -> Result<()> {
    crate::config::private_state_dir(&state_dir())?;
    let path = state_dir().join(CONSENT_EVENTS_FILE);
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new().create(true).append(true).mode(0o600).custom_flags(libc::O_NOFOLLOW).open(&path)?;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs();
        writeln!(file, "{{\"event\":\"consent_refused\",\"surface\":\"{}\",\"at\":{}}}", surface, now)?;
    }
    #[cfg(not(unix))]
    { let _ = (surface, path); }
    Ok(())
}

fn http_client() -> Result<reqwest::Client> {
    reqwest::Client::builder().redirect(reqwest::redirect::Policy::none()).timeout(std::time::Duration::from_secs(10)).build().context("build hub client")
}

#[cfg(test)]
mod tests {
    use super::parse_token_text;

    #[test]
    fn join_token_is_shell_safe_after_shared_line_reader() {
        assert_eq!(parse_token_text("cmj_abc-123_").unwrap(), "cmj_abc-123_");
        assert!(parse_token_text("cmj_abc!").is_err());
        assert!(parse_token_text("cmxt1_ticket").is_err());
    }
}
