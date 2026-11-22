//! Dispatch of every parsed CLI command against the daemon.

use crate::cli::command::*;
use crate::cli::output::*;
use crate::cli::session_folder::new_session_cwd;
use crate::cli::{errors, orchestrate};
use crate::client::Client;
use crate::config::{Config, home};
use crate::daemon::connect;
use crate::rpc::method;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
mod permission;
pub(crate) use permission::{answer_permission, answer_question};

mod extra;
mod standard;

pub(crate) async fn run_client(cmd: Command, json_out: bool, suppress_reads: bool) -> Result<()> {
    if standard::handles(&cmd) {
        standard::run(cmd, json_out, suppress_reads).await
    } else {
        extra::run(cmd, json_out, suppress_reads).await
    }
}

pub(crate) async fn resolve_id(client: &Client, key: &str) -> Result<String> {
    let key = orchestrate::expand_session_key(key)?;
    let v = client.request(method::MUX_INFO, json!({"sessionId": key})).await.map_err(|e| {
        let m = e.to_string().to_lowercase();
        if m.contains("no session") || m.contains("not found") {
            anyhow::Error::from(errors::AppError::no_session(&key))
        } else {
            e
        }
    })?;
    Ok(v.get("sessionId").and_then(Value::as_str).unwrap_or(&key).to_owned())
}
