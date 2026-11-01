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

mod extra;
pub(crate) mod fanout;
pub(crate) mod launch;
mod ls;
mod ls_pages;
mod ls_tools;
pub use ls::LsArgs;
mod parent;
mod send_async;
mod session_move;
mod standard;
pub(crate) mod transfer;

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
mod tests {
    use super::*;
    use crate::rpc::{Message, RpcError};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    #[tokio::test]
    async fn missing_peer_session_allows_relay_but_other_rpc_errors_do_not() {
        for (error, should_relay) in [
            (RpcError::not_found("no session matches \"peer/name\""), true),
            (RpcError::invalid_params("ambiguous session"), false),
            (RpcError::internal("credentials not found"), false),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let socket = dir.path().join("daemon.sock");
            let listener = tokio::net::UnixListener::bind(&socket).unwrap();
            let server = tokio::spawn(async move {
                let (stream, _) = listener.accept().await.unwrap();
                let (rd, mut wr) = stream.into_split();
                let mut lines = BufReader::new(rd).lines();
                for expected in [method::INITIALIZE, method::MUX_INFO] {
                    let line = lines.next_line().await.unwrap().unwrap();
                    let Message::Request { id, method, params } = Message::parse(&line).unwrap()
                    else {
                        panic!("expected request");
                    };
                    assert_eq!(method, expected);
                    let response = if expected == method::INITIALIZE {
                        Message::ok(id, json!({}))
                    } else {
                        assert_eq!(params.unwrap()["sessionId"], "peer/name");
                        Message::err(id, error.clone())
                    };
                    wr.write_all(response.to_line().as_bytes()).await.unwrap();
                }
            });
            let client = Client::connect(&socket).await.unwrap();
            let error = resolve_id(&client, "peer/name").await.unwrap_err();
            server.await.unwrap();
            assert_eq!(crate::cli::send_relay::no_such_session(&error), should_relay, "{error}");
        }
    }
}
