//! `acpmux host ticket new|ls|revoke|full-access` (the minting machine) and
//! `acpmux host join TICKET` (the new one); `cmux host ticket|join` run the
//! same. See `crate::pairing` for the model and `server/pairing.rs` for the
//! daemon's side. Every command prints one JSON object with `--json`; exit
//! codes are 0 ok, 1 failed, 2 usage (`errors.rs`).

use std::sync::Arc;

use anyhow::{Context, Result, anyhow};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message as Frame;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::cli::command::TicketCmd;
use crate::cli::errors::AppError;
use crate::cli::output::print_json;
use crate::client::Client;
use crate::no_panic::JsonExt;
use crate::pairing::{Role, Ticket};
use crate::rpc::{Message, method};

/// The install script a new machine pipes the ticket into
/// (`web/public/tui/install-static.sh`). `CMUX_INSTALL_URL` overrides it.
const INSTALL_URL: &str = "https://cmux.com/tui/install-static.sh";

/// What a daemon-role command shows where the new machine's address goes.
const ADVERTISE_PLACEHOLDER: &str = "<wss:// address of the new machine>";

/// How long a redeem may take end to end.
const REDEEM_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

pub(crate) async fn ticket(client: Arc<Client>, cmd: TicketCmd, json_out: bool) -> Result<()> {
    let v = match cmd {
        TicketCmd::New { role, ttl, url, label } => {
            let role = Role::parse(&role).ok_or_else(|| {
                AppError::usage(format!("--role must be daemon, client or read-only, not {role:?}"))
            })?;
            let ttl = parse_ttl(&ttl)?;
            let mut params = json!({"role": role.as_str(), "ttlSeconds": ttl});
            if let Some(url) = url {
                params.set("url", json!(url));
            }
            if let Some(label) = label {
                params.set("label", json!(label));
            }
            let mut v = client.request(method::MUX_PAIR_TICKET_NEW, params).await?;
            let ticket = v.field("ticket").as_str().unwrap_or_default().to_owned();
            // A daemon-role join also names the address this machine dials
            // the new one at; the placeholder fails until it is filled in.
            let advertise = match role {
                Role::Daemon => format!(" --advertise '{ADVERTISE_PLACEHOLDER}'"),
                Role::Client | Role::ReadOnly | Role::Phone => String::new(),
            };
            v.set("install_command", json!(format!("{}{advertise}", install_command(&ticket))));
            v.set("join_command", json!(format!("cmux host join '{ticket}'{advertise}")));
            if !json_out {
                print_minted(&v);
                return Ok(());
            }
            v
        }
        TicketCmd::Ls => {
            let v = client.request(method::MUX_PAIR_LIST, json!({})).await?;
            if !json_out {
                print_list(&v);
                return Ok(());
            }
            v
        }
        TicketCmd::FullAccess { id, state } => {
            let v = full_access(&client, &id, state == "on").await?;
            if !json_out {
                let name = v.field("device").field("name").as_str().unwrap_or(&id);
                match v.field("allows").as_str() {
                    Some(allows) => println!("Full access on: {allows}"),
                    None => println!(
                        "Full access off for {name}{}",
                        match v.field("held_again").as_u64() {
                            Some(n) if n > 0 =>
                                format!("; {n} chat(s) back in their policy's mode"),
                            _ => String::new(),
                        }
                    ),
                }
                return Ok(());
            }
            v
        }
        TicketCmd::Revoke { id } => {
            let v = client.request(method::MUX_PAIR_REVOKE, json!({"id": id})).await?;
            if !json_out {
                let r = v.field("revoked");
                if let Some(device) = r["used_by"].as_str() {
                    println!(
                        "That ticket was already used; the machine it paired stays paired. Revoke it: cmux host ticket revoke {device}"
                    );
                }
                println!(
                    "revoked {} {}{}{}",
                    r["kind"].as_str().unwrap_or("-"),
                    r["name"].as_str().or(r["id"].as_str()).unwrap_or("-"),
                    if r["already"] == true { " (it already was)" } else { "" },
                    match v.field("closed_connections").as_u64() {
                        Some(n) if n > 0 => format!("; closed {n} open connection(s)"),
                        _ => String::new(),
                    }
                );
                return Ok(());
            }
            v
        }
    };
    print_json(&v);
    Ok(())
}

/// `host ticket full-access ID on|off` (`_acpmux/pair_set`).
async fn full_access(client: &Client, id: &str, on: bool) -> Result<Value> {
    let v = client.request(method::MUX_PAIR_SET, json!({"id": id, "fullAccess": on})).await;
    let person = |e: &anyhow::Error| {
        e.downcast_ref::<crate::client::DaemonError>().is_some_and(|d| {
            d.0.data.as_ref().and_then(|v| v.get("reason")).and_then(Value::as_str)
                == Some(crate::hub::person::REASON)
        })
    };
    match v {
        Err(e) if person(&e) => Err(AppError::new(
            crate::cli::errors::Code::Runtime,
            "person_required",
            "the CLI cannot turn Full access on for a machine: only the cmux app may (Settings > Devices). `cmux host ticket full-access ID off` still turns it off.",
        )
        .into()),
        other => other,
    }
}

/// `900`, `900s`, `15m` or `2h` as seconds.
fn parse_ttl(text: &str) -> Result<u64> {
    let text = text.trim();
    let (digits, unit) = match text.char_indices().find(|(_, c)| !c.is_ascii_digit()) {
        Some((at, _)) => text.split_at(at),
        None => (text, "s"),
    };
    let n: u64 = digits
        .parse()
        .map_err(|_| AppError::usage(format!("--ttl {text:?}: use 900, 15m or 2h")))?;
    let scale = match unit {
        "s" => 1,
        "m" => 60,
        "h" => 3600,
        _ => return Err(AppError::usage(format!("--ttl {text:?}: use 900, 15m or 2h")).into()),
    };
    Ok(n.saturating_mul(scale))
}

fn install_command(ticket: &str) -> String {
    let url = std::env::var("CMUX_INSTALL_URL").unwrap_or_else(|_| INSTALL_URL.to_owned());
    install_line(&url, ticket)
}

/// Installs cmux, then joins with the CLI it installed (at the script's
/// default `~/.cmux/bin`). The ticket goes to `cmux host join`, not to the
/// script: a script that does not join (cmux.com served one on 2026-10-22)
/// would install and stop, and a script that does join would spend the
/// single-use ticket before a second join.
fn install_line(url: &str, ticket: &str) -> String {
    format!("curl -fsSL {url} | sh && \"$HOME/.cmux/bin/cmux\" host join --serve '{ticket}'")
}

fn print_minted(v: &Value) {
    let s = |k: &str| v[k].as_str().unwrap_or("-").to_owned();
    println!("Ticket {} ({}), single use, expires {}.", s("id"), s("role"), s("expires_at"));
    if v["role"] == "daemon" {
        println!(
            "Replace {ADVERTISE_PLACEHOLDER} with the wss:// URL this machine reaches the new one at."
        );
    }
    if s("url").starts_with("ws://") {
        println!(
            "The new machine dials {} on itself: forward that port to this machine first (ssh -L), or mint with --url wss://… instead.",
            s("url")
        );
    }
    println!("On the new machine, run:\n\n  {}\n", s("install_command"));
    println!("Or, where cmux is installed already:\n\n  {}\n", s("join_command"));
    println!("Revoke it: cmux host ticket revoke {}", s("id"));
}

fn print_list(v: &Value) {
    let tickets = v["tickets"].as_array().cloned().unwrap_or_default();
    let devices = v["devices"].as_array().cloned().unwrap_or_default();
    if tickets.is_empty() && devices.is_empty() {
        println!("No tickets and no paired machines. Mint one: cmux host ticket new --role client");
        return;
    }
    for t in &tickets {
        println!(
            "ticket {:<16} {:<9} {:<8} expires {}{}",
            t["id"].as_str().unwrap_or("-"),
            t["role"].as_str().unwrap_or("-"),
            t["state"].as_str().unwrap_or("-"),
            t["expires_at"].as_str().unwrap_or("-"),
            t["label"].as_str().map(|l| format!("  {l}")).unwrap_or_default(),
        );
    }
    for d in &devices {
        println!(
            "device {:<16} {:<16} {:<9} {}",
            d["id"].as_str().unwrap_or("-"),
            d["name"].as_str().unwrap_or("-"),
            d["role"].as_str().unwrap_or("-"),
            if d["revoked_at"].is_string() {
                "revoked".to_owned()
            } else {
                format!(
                    "{} open connection(s){}",
                    d["connections"].as_u64().unwrap_or(0),
                    if d["full_access"] == true { ", Full access on" } else { "" }
                )
            },
        );
    }
}

/// What `host join` was asked.
pub(crate) struct JoinArgs {
    pub ticket: String,
    pub name: Option<String>,
    pub peer_name: Option<String>,
    pub advertise: Option<String>,
}

/// `host join TICKET`: redeem the ticket at the minting machine, then pair in
/// its role: add it as this daemon's peer (client, read-only), or let it add
/// this machine (daemon, at `--advertise`).
pub(crate) async fn join(client: Arc<Client>, args: JoinArgs, json_out: bool) -> Result<()> {
    let ticket = Ticket::decode(&args.ticket).map_err(AppError::usage)?;
    if !crate::pairing::transport_ok(&ticket.url) {
        return Err(anyhow!(
            "refusing to send the ticket to {}: only wss://, or ws:// to a loopback host, carries it",
            ticket.url
        ));
    }
    if ticket.expires_ms <= crate::store::now_ms() {
        return Err(anyhow!("this ticket expired; mint a new one on the other machine"));
    }
    let name = args.name.unwrap_or_else(crate::pairing::machine_name);
    let peer_name = args.peer_name.unwrap_or_else(|| ticket.minter.clone());
    crate::session_name::validate(&peer_name)
        .map_err(|e| AppError::usage(format!("--peer-name: {e}")))?;
    let mut params = json!({"name": name});
    // The credential a daemon-role join issued on this daemon, revoked again
    // when the redeem fails so no unused credential stays live.
    let mut issued_here = None;
    match ticket.role {
        Role::Daemon => {
            let url = args.advertise.ok_or_else(|| {
                AppError::usage("this is a daemon ticket: pass --advertise with the wss:// URL (or ws:// to a loopback host) the other machine reaches this daemon at")
            })?;
            if !crate::pairing::transport_ok(&url) {
                return Err(AppError::usage(
                    "--advertise must be wss://, or ws:// to a loopback host",
                )
                .into());
            }
            // The other machine drives this one: give it a client credential here.
            let issued = client
                .request(method::MUX_PAIR_ISSUE, json!({"name": peer_name, "role": "client"}))
                .await?;
            params.set("advertiseUrl", json!(url));
            params.set("advertiseToken", issued.field("token").clone());
            issued_here = issued.field("deviceId").as_str().map(str::to_owned);
        }
        Role::Client | Role::ReadOnly | Role::Phone => {
            let peers = client.request("_acpmux/peers", json!({})).await?;
            let taken = peers.field("peers").as_array().is_some_and(|ps| {
                ps.iter().any(|p| p["name"].as_str() == Some(peer_name.as_str()))
            });
            if taken {
                return Err(AppError::usage(format!(
                    "this machine already has a peer named {peer_name:?}; pass --peer-name"
                ))
                .into());
            }
        }
    }
    let reply = match tokio::time::timeout(REDEEM_TIMEOUT, redeem(&ticket, params)).await {
        Ok(Ok(reply)) => reply,
        failed => {
            let e = match failed {
                Ok(Err(e)) => e,
                _ => anyhow!(
                    "the other machine did not answer within 30 s ({}). If it paired anyway, run `cmux host ticket revoke {name}` there before joining again",
                    ticket.url
                ),
            };
            if let Some(id) = issued_here {
                let _ = client.request(method::MUX_PAIR_REVOKE, json!({"id": id})).await;
            }
            return Err(e);
        }
    };
    let role = reply.field("role").as_str().and_then(Role::parse).unwrap_or(ticket.role);
    let mut out = json!({
        "joined": true,
        "role": role.as_str(),
        "device_id": reply.field("deviceId"),
        "name": reply.field("name"),
        "minter": reply.field("minter"),
        "url": ticket.url,
    });
    if role == Role::Daemon {
        out.set("peer", reply.field("peer").clone());
    } else {
        let token = reply
            .field("token")
            .as_str()
            .ok_or_else(|| anyhow!("the other machine sent no credential"))?;
        client
            .request(
                "_acpmux/peer_add",
                json!({"name": peer_name, "url": ticket.url, "token": token, "wait": true}),
            )
            .await
            .with_context(|| {
                format!(
                    "paired, but adding the peer here failed; revoke {} on the other machine and join again",
                    reply.field("deviceId").as_str().unwrap_or("the device")
                )
            })?;
        out.set("peer", json!({"name": peer_name, "url": ticket.url}));
    }
    if json_out {
        print_json(&out);
    } else if role == Role::Daemon {
        println!("Joined as a daemon: {} now drives this machine's sessions.", ticket.minter);
    } else {
        println!(
            "Joined as {}: {}'s sessions show here as {peer_name}/<session> (acpmux ls).",
            role.as_str(),
            ticket.minter
        );
    }
    Ok(())
}

/// One `_acpmux/pair_redeem` over a WebSocket that carries the ticket in
/// its upgrade header; the minter answers and closes.
async fn redeem(ticket: &Ticket, params: Value) -> Result<Value> {
    let mut req = ticket.url.as_str().into_client_request().context("the ticket's URL")?;
    req.headers_mut().insert(
        crate::pairing::TICKET_HEADER,
        ticket.secret.parse().map_err(|_| anyhow!("the ticket's secret is damaged"))?,
    );
    let (mut ws, _) = tokio_tungstenite::connect_async(req)
        .await
        .map_err(|e| anyhow!("could not reach {}: {e}", ticket.url))?;
    let request = Message::request(1, method::MUX_PAIR_REDEEM, params);
    ws.send(Frame::Text(request.to_value().to_string().into())).await?;
    while let Some(frame) = ws.next().await {
        let Frame::Text(text) = frame? else { continue };
        return match Message::parse(&text) {
            Ok(Message::Response { error: Some(e), .. }) => {
                Err(crate::client::DaemonError(e).into())
            }
            Ok(Message::Response { result, .. }) => Ok(result.unwrap_or(Value::Null)),
            _ => Err(anyhow!("the other machine answered something else")),
        };
    }
    Err(anyhow!(
        "the other machine closed the connection: the ticket is unknown, expired, revoked or used"
    ))
}

#[cfg(test)]
mod tests {
    use super::install_line;

    /// A scratch folder removed at drop.
    struct Dir(std::path::PathBuf);
    impl Dir {
        fn path(&self) -> &std::path::Path {
            &self.0
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// The line a person pastes on the new machine joins it even when the
    /// install script it pipes into ignores its arguments, as the script
    /// cmux.com served on 2026-10-22 did (it installed cmux and stopped).
    #[test]
    fn the_pasted_line_joins_even_through_an_install_script_that_ignores_the_ticket() {
        let root = std::env::temp_dir().join(format!("acpmux-pair-line-{}", uuid::Uuid::now_v7()));
        let dir = Dir(root);
        let home = dir.path().join("home");
        let bin = dir.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        let log = dir.path().join("cmux.log");
        // An old install script: it installs a cmux that logs its arguments,
        // and never reads "$@".
        let script = format!(
            "mkdir -p \"$HOME/.cmux/bin\"\nprintf '#!/bin/sh\\necho \"$*\" >> {log}\\n' > \"$HOME/.cmux/bin/cmux\"\nchmod 755 \"$HOME/.cmux/bin/cmux\"\n",
            log = log.display()
        );
        let script_path = dir.path().join("install.sh");
        std::fs::write(&script_path, script).unwrap();
        let curl = format!("#!/bin/sh\ncat '{}'\n", script_path.display());
        std::fs::write(bin.join("curl"), curl).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(bin.join("curl"), std::fs::Permissions::from_mode(0o755)).unwrap();

        let line = install_line("https://cmux.example/install.sh", "cmxt1.abc");
        let status = std::process::Command::new("/bin/sh")
            .arg("-c")
            .arg(&line)
            .env("HOME", &home)
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .status()
            .unwrap();
        assert!(status.success(), "{line}");
        let calls = std::fs::read_to_string(&log).unwrap_or_default();
        assert_eq!(calls.trim(), "host join --serve cmxt1.abc", "{line}");
    }
}
