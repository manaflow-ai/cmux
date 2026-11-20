//! `acpmux machine forward add|ls|rm`: the forwards to another machine's named services
//! (`machine_forward.rs`), kept in config.json (`machineForwards`) and bound by the daemon.

use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use crate::cli::command_host::ForwardCmd;
use crate::cli::output::print_json;
use crate::config::Config;
use crate::config::named_services::{MachineForward, forward_listen, owner_home};
use crate::rpc::method;

pub(crate) async fn run(cmd: ForwardCmd, json_out: bool) -> Result<()> {
    match cmd {
        ForwardCmd::Add { name, from, listen_unix, listen_tcp } => {
            let forward = MachineForward { from, listen_unix, listen_tcp };
            let listen =
                forward_listen(&name, &forward, owner_home().as_deref()).map_err(|e| anyhow!(e))?;
            let mut cfg = Config::load()?;
            if let Some((other, _)) = cfg.machine_forwards.iter().find(|(other, f)| {
                other.as_str() != name
                    && forward_listen(other, f, owner_home().as_deref()).ok().as_ref()
                        == Some(&listen)
            }) {
                return Err(anyhow!("forward {other} already listens on {listen}"));
            }
            cfg.machine_forwards.insert(name.clone(), forward.clone());
            cfg.save()?;
            let state = reload_and_read(&name).await;
            if json_out {
                print_json(&json!({"name": name, "from": forward.from,
                    "listen": listen.to_string(), "daemon": state}));
            } else {
                println!("forward {name}: {listen} -> {} ({})", forward.from, describe(&state));
            }
            Ok(())
        }
        ForwardCmd::Rm { name } => {
            let mut cfg = Config::load()?;
            if cfg.machine_forwards.remove(&name).is_none() {
                return Err(anyhow!("no forward named {name}"));
            }
            cfg.save()?;
            let _ = reload_and_read(&name).await;
            if json_out {
                print_json(&json!({"removed": name}));
            } else {
                println!("forward {name} removed");
            }
            Ok(())
        }
        ForwardCmd::Ls => {
            let configured = Config::load()?.machine_forwards;
            let live = read_daemon().await;
            let rows: Vec<Value> = configured
                .iter()
                .map(|(name, f)| {
                    let state = live
                        .as_ref()
                        .and_then(|rows| rows.iter().find(|r| r["name"] == name.as_str()))
                        .cloned();
                    let listen = forward_listen(name, f, owner_home().as_deref())
                        .map(|l| l.to_string())
                        .unwrap_or_else(|e| e);
                    json!({"name": name, "from": f.from, "listen": listen,
                        "daemon": state.unwrap_or(Value::Null)})
                })
                .collect();
            if json_out {
                print_json(&json!({"forwards": rows, "daemonRunning": live.is_some()}));
            } else if rows.is_empty() {
                println!(
                    "no forwards (acpmux machine forward add --name NAME --from MACHINE --listen-unix PATH)"
                );
            } else {
                for row in &rows {
                    println!(
                        "{}  {} -> {}  {}",
                        row["name"].as_str().unwrap_or_default(),
                        row["listen"].as_str().unwrap_or_default(),
                        row["from"].as_str().unwrap_or_default(),
                        describe(&row["daemon"]),
                    );
                }
            }
            Ok(())
        }
    }
}

/// Ask a running daemon to reload, then read `name`'s state. Null when no daemon runs (it binds
/// the forward at its next start).
async fn reload_and_read(name: &str) -> Value {
    let Ok(client) = crate::client::Client::connect(&crate::config::socket_path()).await else {
        return Value::Null;
    };
    if let Err(e) = client.request(method::MUX_RELOAD_CONFIG, json!({})).await {
        return json!({"state": "unavailable", "error": format!("reload: {e:#}")});
    }
    read_daemon()
        .await
        .and_then(|rows| rows.into_iter().find(|r| r["name"] == name))
        .unwrap_or(Value::Null)
}

/// The daemon's forwards, when one runs.
async fn read_daemon() -> Option<Vec<Value>> {
    let client = crate::client::Client::connect(&crate::config::socket_path()).await.ok()?;
    let reply =
        client.request(method::MUX_MACHINE_ROUTES, json!({"forwardsOnly": true})).await.ok()?;
    reply.get("forwards").and_then(Value::as_array).cloned()
}

fn describe(state: &Value) -> String {
    match state.get("state").and_then(Value::as_str) {
        None => "the daemon binds it at its next start".into(),
        Some("listening") => "listening".into(),
        Some("refused") => format!(
            "refused: {}",
            state.pointer("/refusal/error").and_then(Value::as_str).unwrap_or("unknown")
        ),
        Some(other) => {
            format!("{other}: {}", state.get("error").and_then(Value::as_str).unwrap_or_default())
        }
    }
}
