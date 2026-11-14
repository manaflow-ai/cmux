//! Dispatch of every parsed CLI command against the daemon.

use crate::cli::command::*;
use crate::cli::host_budget::{host_pressure_line, warn_host_pressure};
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
pub(crate) use send_async::{list_lines as sent_list_lines, status_line as sent_status_line};

mod extra;
pub(crate) mod fanout;
pub(crate) mod launch;
pub(crate) mod ls;
mod ls_leads;
mod ls_pages;
mod ls_tools;
pub use ls::LsArgs;
mod parent;
mod send_async;
mod session_move;
mod standard;
pub(crate) mod transfer;

pub(crate) async fn run_client(cmd: Command, json_out: bool, suppress_reads: bool) -> Result<()> {
    if let Command::DetachParent { session } = &cmd {
        crate::cli::detach::run(session, json_out).await
    } else if standard::handles(&cmd) {
        standard::run(cmd, json_out, suppress_reads).await
    } else {
        extra::run(cmd, json_out, suppress_reads).await
    }
}

pub(crate) async fn resolve_id(client: &Client, key: &str) -> Result<String> {
    let key = orchestrate::expand_session_key(key)?;
    let v = client.request(method::MUX_INFO, json!({"sessionId": key})).await.map_err(|e| {
        if e.downcast_ref::<crate::client::DaemonError>()
            .is_some_and(|e| e.0.code == crate::rpc::RpcError::not_found("").code)
        {
            anyhow::Error::from(errors::AppError::no_session_from(&key, &e))
        } else {
            e
        }
    })?;
    crate::cli::resolve::routed_id(&v)
}

#[cfg(all(test, unix))]
mod tests;
