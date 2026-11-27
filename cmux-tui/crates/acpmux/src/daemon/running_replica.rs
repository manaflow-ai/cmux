//! Ordinary Cloud chats' opt-in replica. A clock, not incoming tokens, drives capture so a
//! silent tool remains recoverable. One operation at a time also covers manual checkpoints.
//! Recovery makes an idle copy; it never claims the source identity or executes its queue.

use crate::hub::Hub;
use crate::store::SessionStatus;
use anyhow::{Context, Result, bail};
use cmux_session_cloud::{Cloud, config::Config, replica};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

static OPERATION: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
const PERIOD: Duration = Duration::from_secs(30);

fn enabled(state: &Path) -> Result<bool> {
    Ok(Config::load_in(state)?.is_some_and(|config| config.running_replica))
}

fn active(status: SessionStatus, turn: bool, auto: bool) -> bool {
    !auto && (turn || matches!(status, SessionStatus::Running | SessionStatus::Waiting))
}

/// No traffic, key creation, or enrollment when the separate opt-in is absent.
pub(super) async fn run(hub: Arc<Hub>) {
    loop {
        let state = crate::config::home();
        let on = tokio::task::spawn_blocking(move || enabled(&state)).await;
        match on {
            Ok(Ok(true)) => {
                for session in hub.session_handles() {
                    if !active(
                        session.meta().status,
                        session.turn().is_some(),
                        hub.auto_record(&session).is_some(),
                    ) {
                        continue;
                    }
                    if let Err(error) = request(
                        hub.clone(),
                        json!({
                            "action": "checkpoint", "sessionId": session.id,
                        }),
                    )
                    .await
                    {
                        tracing::warn!(session_id = %session.id, %error, "running chat replica failed; previous root retained");
                    }
                }
            }
            Ok(Err(error)) => tracing::warn!(%error, "running chat replica configuration"),
            Err(error) => tracing::warn!(%error, "running chat replica worker"),
            _ => {}
        }
        // Delay after completion: no catch-up burst or overlapping uploads on a slow store.
        tokio::time::sleep(PERIOD).await;
    }
}

fn cloud(state: &Path, recovery: bool) -> Result<Arc<Cloud>> {
    let config =
        Config::load_in(state)?.context("cloud history is not configured (session-cloud.json)")?;
    if !recovery && !config.running_replica {
        bail!(
            "running replicas are off; set runningReplica to true in session-cloud.json to opt in"
        );
    }
    // A new key cannot decrypt an existing replica. Fail before creating any recovery state.
    if recovery && !config.key_path().is_file() {
        bail!("recovery needs the original cloud-history key at the configured keyFile");
    }
    Cloud::get_in(state)?.context("cloud history is not configured")
}

fn required<'a>(params: &'a Value, field: &str) -> Result<&'a str> {
    params
        .get(field)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .with_context(|| format!("{field} is required"))
}

fn receipts_path(state: &Path) -> PathBuf {
    state.join("running-replica-receipts.json")
}

fn receipts(state: &Path) -> Result<Value> {
    match std::fs::read(receipts_path(state)) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes)?),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
        Err(error) => Err(error.into()),
    }
}

/// The RPC caller checks local-only origin before reaching this handler.
pub(crate) async fn request(hub: Arc<Hub>, params: Value) -> Result<Value> {
    let state = crate::config::home();
    match required(&params, "action")? {
        "address" => {
            let session_id = required(&params, "sessionId")?.to_string();
            tokio::task::spawn_blocking(move || {
                let cloud = cloud(&state, true)?;
                Ok(json!({"pair": replica::pair(&session_id, &cloud)?}))
            }).await?
        }
        "status" => tokio::task::spawn_blocking(move || {
            Ok(json!({
                "enabled": enabled(&state)?,
                "periodSeconds": PERIOD.as_secs(),
                "replicas": receipts(&state)?,
                "recovery": "running-replica recover PAIR --cwd PATH; requires original history key and authorized cloud credentials",
            }))
        }).await?,
        "checkpoint" => {
            let _operation = OPERATION.lock().await;
            let session = hub.resolve(required(&params, "sessionId")?)
                .map_err(|error| anyhow::anyhow!(error.message))?;
            if hub.auto_record(&session).is_some() {
                bail!("Auto chats use their existing fenced checkpoint holder");
            }
            // Keep the serialization guard inside the blocking task if the requester disconnects.
            // This synchronous capture runs off the runtime's I/O threads.
            tokio::task::spawn_blocking(move || {
                let _operation = _operation;
                let cloud = cloud(&state, false)?;
                let temp = tempfile::tempdir()?;
                let bundle = hub.capture_running_replica(&session, &temp.path().join("bundle"))?;
                let receipt = replica::publish(&bundle, &session.id, &cloud)?;
                let result = json!({"receipt": receipt, "checkpointedAt": crate::store::now_ms()});
                let mut saved = receipts(&state)?;
                saved[&session.id] = result.clone();
                cmux_session_cloud::write_durable(&receipts_path(&state), &serde_json::to_vec(&saved)?)?;
                Ok(result)
            }).await?
        }
        "recover" => {
            let _operation = OPERATION.lock().await;
            let pair = required(&params, "pair")?.to_string();
            let cwd = PathBuf::from(required(&params, "cwd")?);
            if !cwd.is_absolute() || !cwd.is_dir() {
                bail!("cwd must be an existing absolute directory restored separately from the machine snapshot");
            }
            let (temp, bundle, receipt) = tokio::task::spawn_blocking(move || -> Result<_> {
                let cloud = cloud(&state, true)?;
                let temp = tempfile::tempdir()?;
                let bundle = temp.path().join("bundle");
                let receipt = replica::recover(&pair, &bundle, &cloud)?;
                Ok((temp, bundle, receipt))
            }).await??;
            let recovered = hub.recover_running_replica(&bundle, &cwd, params.get("name").and_then(Value::as_str)).await?;
            drop(temp);
            Ok(json!({"recovered": recovered, "receipt": receipt}))
        }
        _ => bail!("action must be status, address, checkpoint, or recover"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn running_replica_is_separate_opt_in_and_keeps_silent_turns() {
        let dir = tempfile::tempdir().unwrap();
        assert!(!enabled(dir.path()).unwrap());
        std::fs::write(dir.path().join("session-cloud.json"), r#"{"store":"fs:/unused"}"#).unwrap();
        assert!(!enabled(dir.path()).unwrap());
        std::fs::write(
            dir.path().join("session-cloud.json"),
            r#"{"store":"fs:/unused","runningReplica":true}"#,
        )
        .unwrap();
        assert!(enabled(dir.path()).unwrap());
        assert!(active(SessionStatus::Running, false, false));
        assert!(active(SessionStatus::Waiting, false, false));
        assert!(active(SessionStatus::Ready, true, false));
        assert!(!active(SessionStatus::Idle, false, false));
        assert!(!active(SessionStatus::Running, true, true));
    }

    #[test]
    fn running_replica_recovery_does_not_create_a_new_key() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("session-cloud.json"), r#"{"store":"fs:/unused"}"#).unwrap();
        assert!(cloud(dir.path(), true).err().unwrap().to_string().contains("original"));
        assert!(!dir.path().join("session-cloud/key").exists());
    }
}
