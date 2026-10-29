//! Cloud machine onboarding. The join secret is read from stdin and is never
//! placed in argv, the environment, a URL, or a diagnostic message.

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::{Read, IsTerminal};
use std::path::{Path, PathBuf};

pub const CAPABILITY: &str = "machine.join.stdin.v1";
pub const DEFAULT_HUB: &str = "https://cmux-platform-development.debussy.workers.dev";
const MAX_TOKEN_BYTES: usize = 4096;
const CREDENTIAL_FILE: &str = "machine-credential.json";
const CONSENT_FILE: &str = "consent.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MachineCredential {
    pub credential: String,
    pub machine_id: String,
    pub team_id: String,
    pub name: String,
    pub hub_origin: String,
    pub last_heartbeat: Option<String>,
    pub revoked: bool,
    pub mesh_identity: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Consent {
    pub screen: ConsentState,
    pub control: ConsentState,
    pub granted_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ConsentState { #[default] None, Granted }

fn state_dir() -> PathBuf { crate::config::home() }
fn credential_path() -> PathBuf { state_dir().join(CREDENTIAL_FILE) }
fn consent_path() -> PathBuf { state_dir().join(CONSENT_FILE) }

pub fn read_token() -> Result<String> {
    let mut input = Vec::new();
    std::io::stdin().read_to_end(&mut input).context("read join token from stdin")?;
    if input.len() > MAX_TOKEN_BYTES { return Err(anyhow!("join token is too long")); }
    let text = std::str::from_utf8(&input).map_err(|_| anyhow!("join token is not valid UTF-8"))?;
    let mut lines = text.lines();
    let token = lines.next().map(str::trim).unwrap_or_default();
    if token.is_empty() { return Err(anyhow!("join token is empty")); }
    if lines.any(|line| !line.trim().is_empty()) { return Err(anyhow!("join stdin must contain one token line")); }
    if !token.starts_with("cmj_") || token.len() > MAX_TOKEN_BYTES { return Err(anyhow!("join token is malformed")); }
    Ok(token.to_owned())
}

fn origin(value: Option<String>) -> String {
    value.or_else(|| std::env::var("CMUX_PLATFORM_ORIGIN").ok()).unwrap_or_else(|| DEFAULT_HUB.to_owned()).trim_end_matches('/').to_owned()
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
    std::fs::File::open(path).ok().and_then(|f| serde_json::from_reader(f).ok()).unwrap_or_default()
}

pub async fn join(hub: Option<String>, name: Option<String>, replace: bool, json_out: bool) -> Result<()> {
    let token = read_token().map_err(|e| crate::cli::errors::AppError::new(crate::cli::errors::Code::Usage, "join.malformed", e.to_string()).with_exit(2))?;
    let existing = load().map_err(|e| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.store", e.to_string()).with_exit(5))?;
    let hub = origin(hub);
    if let Some(existing) = existing && !replace {
        if json_out { crate::cli::output::print_json(&json!({"joined":false,"alreadyJoined":true,"machineId":existing.machine_id,"teamId":existing.team_id,"name":existing.name,"hubOrigin":existing.hub_origin})); }
        else { println!("already joined ({})", existing.machine_id); }
        return Ok(());
    }
    let name = local_name(name);
    let identity = load().ok().flatten().map(|r| r.mesh_identity).unwrap_or_else(mesh_identity);
    let platform = if cfg!(target_os = "macos") { "macos" } else { "linux" };
    let response = reqwest::Client::new().post(format!("{hub}/v1/machines/join-tokens/redeem"))
        .json(&json!({"token": token, "platform": platform, "hostname": name, "name": name, "meshIdentity": identity}))
        .send().await.map_err(|_| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.hub", "hub unreachable").with_exit(4))?;
    let status = response.status();
    let body: Value = response.json().await.unwrap_or_else(|_| json!({}));
    if !status.is_success() {
        let code = body.get("code").and_then(Value::as_str).unwrap_or_default();
        let exit = if status.as_u16() == 410 || code.contains("expired") { 3 } else if status.as_u16() == 409 || code.contains("used") { 3 } else if status.as_u16() == 404 { 3 } else { 1 };
        return Err(crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, code, "machine join failed").with_exit(exit).into());
    }
    let credential = body.get("credential").and_then(Value::as_str).ok_or_else(|| anyhow!("join response omitted credential"))?;
    let record = MachineCredential { credential: credential.to_owned(), machine_id: body["machineId"].as_str().unwrap_or_default().to_owned(), team_id: body["teamId"].as_str().unwrap_or_default().to_owned(), name, hub_origin: hub.clone(), last_heartbeat: None, revoked: false, mesh_identity: identity };
    save(&record).map_err(|e| crate::cli::errors::AppError::new(crate::cli::errors::Code::Runtime, "join.store", e.to_string()).with_exit(5))?;
    let relay = json!({"url": format!("{hub}/v1/mesh"), "tokenCommand": "acpmux host join --credential"});
    crate::config::write_atomic(&state_dir().join("mesh-relay.json"), serde_json::to_vec_pretty(&relay)?.as_slice()).ok();
    if json_out { crate::cli::output::print_json(&json!({"joined":true,"alreadyJoined":false,"machineId":record.machine_id,"teamId":record.team_id,"name":record.name,"hubOrigin":hub})); }
    else { println!("joined {} ({})", record.name, record.machine_id); }
    Ok(())
}

pub async fn status(hub: Option<String>, json_out: bool) -> Result<()> {
    let record = load()?.unwrap_or(MachineCredential { credential: String::new(), machine_id: String::new(), team_id: String::new(), name: local_name(None), hub_origin: origin(hub), last_heartbeat: None, revoked: false, mesh_identity: String::new() });
    let mut out = json!({"credentialPresent": !record.credential.is_empty(), "machineId": record.machine_id, "teamId": record.team_id, "hubOrigin": record.hub_origin, "hubReachable": false, "lastHeartbeat": record.last_heartbeat, "revoked": record.revoked, "consent": load_consent(), "credentialStore":"file", "credentialPath":credential_path(), "credentialMode":"0600", "daemonRunning":false, "meshRelayConfigured":state_dir().join("mesh-relay.json").exists(), "build": crate::hub::BUILD, "channel":"feat-cmux-next"});
    if !record.credential.is_empty() {
        if let Ok(res) = reqwest::Client::new().get(format!("{}/sessions", record.hub_origin.trim_end_matches('/').to_owned() + "/v1/mesh")).bearer_auth(&record.credential).send().await {
            out["hubReachable"] = json!(res.status().is_success() || res.status().as_u16() == 401);
        }
    }
    if json_out { crate::cli::output::print_json(&out); } else if out["revoked"] == true { println!("revoked: run machine add again"); } else { println!("credential: {}\nhub: {}\nlast heartbeat: {}", if out["credentialPresent"] == true { "present" } else { "missing" }, if out["hubReachable"] == true { "reachable" } else { "unreachable" }, out["lastHeartbeat"].as_str().unwrap_or("never")); }
    Ok(())
}

pub fn grant_consent(surface: &str) -> Result<()> {
    if !std::io::stdin().is_terminal() || std::env::var_os("ACPMUX_SESSION_ID").is_some() { return Err(anyhow!("consent requires the local person's terminal")); }
    let mut consent = load_consent();
    let now = format!("{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs());
    match surface { "screen" => consent.screen = ConsentState::Granted, "control" => consent.control = ConsentState::Granted, _ => return Err(anyhow!("use --screen or --control")) }
    consent.granted_at = Some(now);
    crate::config::private_state_dir(&state_dir())?;
    crate::config::write_atomic(&consent_path(), &serde_json::to_vec_pretty(&consent)?)
}
