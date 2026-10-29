//! Cloud machine onboarding. The join secret is read from stdin and is never
//! placed in argv, the environment, a URL, or a diagnostic message.

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::{IsTerminal, Read};
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
    #[serde(rename = "meshPeerId")]
    pub mesh_identity: String,
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
    // Read at most one byte beyond the bound. This avoids an unbounded
    // allocation when a broken installer pipes a large file to us.
    let mut input = Vec::new();
    std::io::stdin().take((MAX_TOKEN_BYTES + 1) as u64).read_to_end(&mut input).context("read join token from stdin")?;
    parse_token(&input)
}

fn parse_token(input: &[u8]) -> Result<String> {
    if input.len() > MAX_TOKEN_BYTES { return Err(anyhow!("join token is too long")); }
    if !input.ends_with(b"\n") { return Err(anyhow!("join token must be newline terminated")); }
    let text = std::str::from_utf8(&input).map_err(|_| anyhow!("join token is not valid UTF-8"))?;
    let mut lines = text.lines();
    let token = lines.next().map(str::trim).unwrap_or_default();
    if token.is_empty() { return Err(anyhow!("join token is empty")); }
    if lines.any(|line| !line.trim().is_empty()) { return Err(anyhow!("join stdin must contain one token line")); }
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

fn mesh_identity() -> String {
    format!("daemon_{}", uuid::Uuid::now_v7().simple())
}

fn save(record: &MachineCredential) -> Result<()> {
    crate::config::private_state_dir(&state_dir())?;
    crate::config::write_atomic(&credential_path(), &serde_json::to_vec_pretty(record)?)
}

fn load() -> Result<Option<MachineCredential>> {
    let path = credential_path();
    if !path.exists() { return Ok(None); }
    let file = crate::config::private_state_file(&path)?;
    Ok(Some(serde_json::from_reader(file).context("read machine credential")?))
}

fn load_consent() -> Consent {
    let path = consent_path();
    crate::config::private_state_file(&path).ok().and_then(|f| serde_json::from_reader(f).ok()).unwrap_or_default()
}

pub async fn join(hub: Option<String>, name: Option<String>, replace: bool, json_out: bool) -> Result<()> {
    let existing = load().map_err(|e| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.store", e.to_string()).with_exit(5))?;
    if let Some(existing) = existing && !replace {
        if json_out { crate::cli::output::print_json(&json!({"joined":false,"alreadyJoined":true,"machineId":existing.machine_id,"teamId":existing.team_id,"name":existing.name,"hubOrigin":existing.hub_origin})); }
        else { println!("already joined ({})", existing.machine_id); }
        return Ok(());
    }
    let token = read_token().map_err(|e| crate::cli::errors::AppError::new(crate::cli::errors::Code::Usage, "join.malformed", e.to_string()).with_exit(2))?;
    let hub = origin(hub).map_err(|_| crate::cli::errors::AppError::new(crate::cli::errors::Code::Usage, "join.malformed", "hub origin is malformed").with_exit(2))?;
    let name = local_name(name);
    let identity = load().ok().flatten().map(|r| r.mesh_identity).unwrap_or_else(mesh_identity);
    let platform = if cfg!(target_os = "macos") { "macos" } else { "linux" };
    let response = http_client().map_err(|_| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.hub", "hub unreachable").with_exit(4))?.post(format!("{hub}/v1/machines/join-tokens/redeem"))
        .json(&json!({"token": token, "platform": platform, "hostname": name, "name": name, "meshPeerId": identity}))
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
    let record = MachineCredential { credential: credential.to_owned(), machine_id: machine_id.to_owned(), team_id: team_id.to_owned(), name, hub_origin: hub.clone(), last_heartbeat: None, revoked: false, mesh_identity: body.get("meshPeerId").and_then(Value::as_str).unwrap_or(&identity).to_owned() };
    save(&record).map_err(|e| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.store", e.to_string()).with_exit(5))?;
    if json_out { crate::cli::output::print_json(&json!({"joined":true,"alreadyJoined":false,"machineId":record.machine_id,"teamId":record.team_id,"name":record.name,"hubOrigin":hub})); }
    else { println!("joined {} ({})", record.name, record.machine_id); }
    Ok(())
}

pub async fn status(hub: Option<String>, json_out: bool) -> Result<()> {
    let fallback_hub = origin(hub)?;
    let record = load()?.unwrap_or(MachineCredential { credential: String::new(), machine_id: String::new(), team_id: String::new(), name: local_name(None), hub_origin: fallback_hub, last_heartbeat: None, revoked: false, mesh_identity: String::new() });
    let mut out = json!({"credentialPresent": !record.credential.is_empty(), "machineId": record.machine_id, "teamId": record.team_id, "hubOrigin": record.hub_origin, "hubReachable": false, "lastHeartbeat": record.last_heartbeat, "revoked": record.revoked, "consent": load_consent(), "credentialStore":"file", "credentialPath":credential_path(), "credentialMode":"0600", "daemonRunning":false, "meshRelayConfigured":state_dir().join("mesh-relay.json").exists(), "build": crate::hub::BUILD, "channel":"feat-cmux-next"});
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
    use super::parse_token;

    #[test]
    fn join_token_requires_one_newline_terminated_shell_safe_line() {
        assert_eq!(parse_token(b"cmj_abc-123_\n").unwrap(), "cmj_abc-123_");
        assert!(parse_token(b"cmj_abc").is_err());
        assert!(parse_token(b"cmj_abc!\n").is_err());
        assert!(parse_token(b"cmj_a\nsecond\n").is_err());
    }
}
