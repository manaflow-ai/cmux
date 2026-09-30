//! `acpmux host setup` and `host update`: install or refresh the daemon on
//! a machine reached over ssh, then register it as a peer. macOS remotes
//! get a launchd agent; others get a nohup fallback.

use crate::cli::output::print_json;
use acpmux::client::Client;
use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::process::Command;
use std::sync::Arc;

fn ssh(host: &str, script: &str) -> Result<String> {
    let out = Command::new("ssh")
        .args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, script])
        .output()
        .with_context(|| format!("ssh {host}"))?;
    if !out.status.success() {
        return Err(anyhow!("ssh {host} failed: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// Copy this very binary to the remote `~/.local/bin/acpmux` (rm then mv,
/// never in place: macOS kills a running binary that is overwritten).
fn push_binary(host: &str) -> Result<String> {
    let exe = std::env::current_exe()?;
    ssh(host, "mkdir -p ~/.local/bin ~/.acpmux")?;
    let status = Command::new("scp")
        .args([
            "-q",
            "-o",
            "BatchMode=yes",
            &exe.to_string_lossy(),
            &format!("{host}:.local/bin/acpmux.new"),
        ])
        .status()
        .context("scp")?;
    if !status.success() {
        return Err(anyhow!("scp to {host} failed"));
    }
    ssh(
        host,
        "rm -f ~/.local/bin/acpmux && mv ~/.local/bin/acpmux.new ~/.local/bin/acpmux && chmod +x ~/.local/bin/acpmux && ~/.local/bin/acpmux --version",
    )
}

const PLIST: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.acpmux.daemon</string>
  <key>ProgramArguments</key><array><string>__HOME__/.local/bin/acpmux</string><string>daemon</string><string>run</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>__HOME__/.local/bin:__HOME__/.bun/bin:__HOME__/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string><key>HOME</key><string>__HOME__</string></dict>
  <key>WorkingDirectory</key><string>__HOME__</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>__HOME__/.acpmux/launchd.log</string>
  <key>StandardErrorPath</key><string>__HOME__/.acpmux/launchd.log</string>
</dict></plist>
"#;

/// (Re)start the remote daemon: launchd on macOS, nohup elsewhere.
fn restart_daemon(host: &str) -> Result<String> {
    let os = ssh(host, "uname -s")?;
    if os == "Darwin" {
        ssh(
            host,
            "launchctl kickstart -k gui/$(id -u)/com.acpmux.daemon 2>/dev/null || (launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.acpmux.daemon.plist && echo bootstrapped)",
        )?;
    } else {
        ssh(
            host,
            "~/.local/bin/acpmux daemon shutdown >/dev/null 2>&1; sleep 1; nohup ~/.local/bin/acpmux daemon run >> ~/.acpmux/launchd.log 2>&1 &",
        )?;
    }
    // Let it come up, then report.
    std::thread::sleep(std::time::Duration::from_secs(2));
    ssh(host, "~/.local/bin/acpmux --json daemon status 2>/dev/null | head -c 400 || echo starting")
}

pub(crate) async fn setup(
    client: Arc<Client>,
    host: &str,
    name: Option<String>,
    port: u16,
    json_out: bool,
) -> Result<()> {
    let name = name.unwrap_or_else(|| {
        host.split('@').next_back().unwrap_or(host).split('.').next().unwrap_or(host).to_owned()
    });
    let version = push_binary(host)?;
    // Config: keep an existing one, but make sure the websocket listener and token exist.
    let existing = ssh(host, "cat ~/.acpmux/config.json 2>/dev/null || echo '{}'")?;
    let mut cfg: Value = serde_json::from_str(&existing).unwrap_or_else(|_| json!({}));
    let token =
        cfg.pointer("/websocket/token").and_then(Value::as_str).map(str::to_owned).unwrap_or_else(
            || {
                let mut b = [0u8; 24];
                getrandom_fill(&mut b);
                b.iter().map(|x| format!("{x:02x}")).collect()
            },
        );
    cfg["websocket"] = json!({"listen": format!("127.0.0.1:{port}"), "token": token});
    if cfg.get("store").is_none() {
        cfg["store"] = json!({"mode": "local"});
    }
    if cfg.get("permissionPolicy").is_none() {
        cfg["permissionPolicy"] = json!("ask");
    }
    let cfg_text = serde_json::to_string_pretty(&cfg)?;
    ssh(host, &format!("cat > ~/.acpmux/config.json <<'ACPMUX_CFG'\n{cfg_text}\nACPMUX_CFG"))?;
    let os = ssh(host, "uname -s")?;
    if os == "Darwin" {
        let home = ssh(host, "echo $HOME")?;
        let plist = PLIST.replace("__HOME__", &home);
        ssh(
            host,
            &format!(
                "mkdir -p ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/com.acpmux.daemon.plist <<'ACPMUX_PLIST'\n{plist}\nACPMUX_PLIST\nlaunchctl bootout gui/$(id -u)/com.acpmux.daemon 2>/dev/null || true; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.acpmux.daemon.plist"
            ),
        )?;
    } else {
        ssh(
            host,
            "~/.local/bin/acpmux daemon shutdown >/dev/null 2>&1; sleep 1; nohup ~/.local/bin/acpmux daemon run >> ~/.acpmux/launchd.log 2>&1 &",
        )?;
    }
    std::thread::sleep(std::time::Duration::from_secs(2));
    let status = ssh(host, "~/.local/bin/acpmux daemon status 2>/dev/null | head -3")?;
    // Register (or re-register) the peer.
    let url = if port == 47811 { format!("ssh://{host}") } else { format!("ssh://{host}:{port}") };
    let peers = client.request("_acpmux/peers", json!({})).await?;
    let known = peers
        .get("peers")
        .and_then(Value::as_array)
        .map(|a| a.iter().any(|p| p.get("name").and_then(Value::as_str) == Some(name.as_str())))
        .unwrap_or(false);
    if !known {
        client.request("_acpmux/peer_add", json!({"name": name, "url": url})).await?;
    }
    tokio::time::sleep(std::time::Duration::from_millis(2500)).await;
    let peers = client.request("_acpmux/peers", json!({})).await?;
    if json_out {
        print_json(
            &json!({"host": host, "name": name, "remoteVersion": version, "status": status, "peers": peers.get("peers")}),
        );
    } else {
        println!("{host}: {version}");
        for l in status.lines() {
            println!("  {l}");
        }
        let p = peers.get("peers").and_then(Value::as_array).and_then(|a| {
            a.iter().find(|p| p.get("name").and_then(Value::as_str) == Some(name.as_str())).cloned()
        });
        println!(
            "peer {name}: {}",
            p.as_ref()
                .and_then(|p| p.get("connected"))
                .and_then(Value::as_bool)
                .map(|c| if c { "connected" } else { "connecting…" })
                .unwrap_or("unknown")
        );
    }
    Ok(())
}

/// Update one ssh peer, or every one, to this binary and restart it.
pub(crate) async fn update(
    client: Arc<Client>,
    name: Option<String>,
    all: bool,
    json_out: bool,
) -> Result<()> {
    let peers = client.request("_acpmux/peers", json!({})).await?;
    let list: Vec<Value> =
        peers.get("peers").and_then(Value::as_array).cloned().unwrap_or_default();
    let targets: Vec<(String, String)> = list
        .iter()
        .filter_map(|p| {
            let n = p.get("name").and_then(Value::as_str)?;
            let url = p.get("url").and_then(Value::as_str)?;
            let host = url
                .strip_prefix("ssh://")?
                .rsplit_once(':')
                .map(|(h, _)| h)
                .unwrap_or(url.strip_prefix("ssh://")?);
            Some((n.to_owned(), host.to_owned()))
        })
        .filter(|(n, _)| all || name.as_deref() == Some(n.as_str()))
        .collect();
    if targets.is_empty() {
        return Err(anyhow!("no ssh peer to update (name one, or --all)"));
    }
    let mut rows = Vec::new();
    for (n, host) in targets {
        let outcome = push_binary(&host).and_then(|v| restart_daemon(&host).map(|s| (v, s)));
        match outcome {
            Ok((version, status)) => {
                if !json_out {
                    println!("{n} ({host}): {version}");
                }
                rows.push(json!({"peer": n, "host": host, "version": version, "status": status, "ok": true}));
            }
            Err(e) => {
                if !json_out {
                    eprintln!("{n} ({host}): {e}");
                }
                rows.push(json!({"peer": n, "host": host, "error": e.to_string(), "ok": false}));
            }
        }
    }
    tokio::time::sleep(std::time::Duration::from_millis(3000)).await;
    let peers = client.request("_acpmux/peers", json!({})).await?;
    if json_out {
        print_json(&json!({"updated": rows, "peers": peers.get("peers")}));
    } else {
        for p in peers.get("peers").and_then(Value::as_array).cloned().unwrap_or_default() {
            println!(
                "{:<16} {:<10} {}",
                p.get("name").and_then(Value::as_str).unwrap_or(""),
                if p.get("connected").and_then(Value::as_bool).unwrap_or(false) {
                    "connected"
                } else {
                    "offline"
                },
                p.get("remoteBuild").and_then(Value::as_str).unwrap_or("?")
            );
        }
    }
    if rows.iter().any(|r| r.get("ok") == Some(&json!(false))) {
        std::process::exit(1);
    }
    Ok(())
}

fn getrandom_fill(buf: &mut [u8]) {
    // /dev/urandom is always there on the platforms acpmux runs on.
    use std::io::Read;
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(buf);
    }
}
