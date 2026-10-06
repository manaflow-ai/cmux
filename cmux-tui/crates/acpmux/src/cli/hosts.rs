//! `acpmux host setup` and `host update`: install or refresh the daemon on
//! a machine reached over ssh, then register it as a peer. macOS remotes
//! get a launchd agent; others get a nohup fallback.

use crate::cli::output::print_json;
use crate::client::Client;
use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::process::Command;
use std::sync::Arc;

/// An ssh destination given on the command line or taken from a peer URL,
/// checked like a peer's (`peer::ssh_target`): never an ssh option.
fn checked_host(host: &str) -> Result<&str> {
    let t = crate::peer::ssh_target(&format!("ssh://{host}"))
        .map_err(|why| anyhow!("refusing that ssh host: {why}"))?;
    if t.destination != host {
        return Err(anyhow!("refusing that ssh host: give the host without a port"));
    }
    Ok(host)
}

/// `ssh ... -- HOST SCRIPT`: `--` before the destination; the script is
/// acpmux's own fixed text.
fn ssh_argv(host: &str, script: &str) -> Result<Vec<String>> {
    let host = checked_host(host)?;
    Ok(["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", host, script]
        .iter()
        .map(|s| s.to_string())
        .collect())
}

/// `scp -q -o BatchMode=yes -- LOCAL HOST:REMOTE`.
fn scp_push_argv(host: &str, local: &str, remote: &str) -> Result<Vec<String>> {
    let host = checked_host(host)?;
    Ok(vec![
        "-q".into(),
        "-o".into(),
        "BatchMode=yes".into(),
        "--".into(),
        local.to_owned(),
        format!("{host}:{remote}"),
    ])
}

/// `scp -rq -o BatchMode=yes -- HOST:REMOTE LOCAL` for a bundle an ssh peer
/// made. `remote` comes from the peer's reply: only a plain absolute or
/// home path is accepted (a remote scp may hand it to a shell).
pub(crate) fn scp_fetch_argv(peer_url: &str, remote: &str, local: &str) -> Result<Vec<String>> {
    let t =
        crate::peer::ssh_target(peer_url).map_err(|why| anyhow!("refusing that peer: {why}"))?;
    let plain = (remote.starts_with('/') || remote.starts_with("~/"))
        && remote.bytes().all(|b| b.is_ascii_alphanumeric() || b"/._-~+".contains(&b));
    if !plain {
        return Err(anyhow!("refusing the bundle path the peer sent (not a plain path)"));
    }
    Ok(vec![
        "-rq".into(),
        "-o".into(),
        "BatchMode=yes".into(),
        "--".into(),
        format!("{}:{remote}", t.destination),
        local.to_owned(),
    ])
}

fn ssh(host: &str, script: &str) -> Result<String> {
    let out = Command::new("ssh")
        .args(ssh_argv(host, script)?)
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
        .args(scp_push_argv(host, &exe.to_string_lossy(), ".local/bin/acpmux.new")?)
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

/// A remote script that runs `cmd` and keeps only the start of its output
/// (`limit`, such as `head -3`), failing when `cmd` fails: a plain pipe into
/// `head` would answer with head's exit status instead.
fn capped(cmd: &str, limit: &str) -> String {
    format!("out=$({cmd}); rc=$?; printf '%s\\n' \"$out\" | {limit}; exit $rc")
}

/// Restart the daemon away from launchd: `daemon shutdown` returns once the
/// old daemon released its lock, and `daemon start` returns once the new one
/// accepts clients (its readiness pipe), so no step waits on a timer.
fn restart_detached(json: bool) -> String {
    let start = if json {
        capped("~/.local/bin/acpmux --json daemon start", "head -c 400")
    } else {
        capped("~/.local/bin/acpmux daemon start", "head -3")
    };
    format!("~/.local/bin/acpmux daemon shutdown >/dev/null 2>&1; {start}")
}

/// Read the daemon's status after launchd (re)started it; a daemon that is
/// still not running is an error, not a status line.
fn launchd_status(host: &str, json: bool) -> Result<String> {
    let status = if json {
        ssh(host, &capped("~/.local/bin/acpmux --json daemon status", "head -c 400"))?
    } else {
        ssh(host, &capped("~/.local/bin/acpmux daemon status", "head -3"))?
    };
    let stopped = status.starts_with("daemon not running")
        || serde_json::from_str::<Value>(&status)
            .ok()
            .and_then(|v| v.get("running").and_then(Value::as_bool))
            == Some(false);
    if stopped {
        return Err(anyhow!("the daemon on {host} did not start: {status}"));
    }
    Ok(status)
}

/// launchd starts the daemon on its own schedule and has no readiness
/// callback, so a launchd host is given this long before its status is read.
const LAUNCHD_START_GRACE: std::time::Duration = std::time::Duration::from_secs(2);

/// (Re)start the remote daemon: launchd on macOS, a detached start elsewhere.
fn restart_daemon(host: &str) -> Result<String> {
    let os = ssh(host, "uname -s")?;
    if os != "Darwin" {
        return ssh(host, &restart_detached(true));
    }
    ssh(
        host,
        "launchctl kickstart -k gui/$(id -u)/com.acpmux.daemon 2>/dev/null || (launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.acpmux.daemon.plist && echo bootstrapped)",
    )?;
    std::thread::sleep(LAUNCHD_START_GRACE);
    launchd_status(host, true)
}

/// Connect a peer now and answer once that attempt settled: add (or
/// replace) it with `url`, or reconnect a known one at its configured url
/// (its daemon was just restarted).
async fn connect_peer(client: &Client, name: &str, url: Option<&str>) -> Result<Value> {
    match url {
        Some(url) => {
            client
                .request("_acpmux/peer_add", json!({"name": name, "url": url, "wait": true}))
                .await
        }
        None => client.request("_acpmux/peer_reconnect", json!({"name": name, "wait": true})).await,
    }
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
    let kept = cfg.pointer("/websocket/token").and_then(Value::as_str).map(str::to_owned);
    let token = match kept.clone() {
        Some(t) => t,
        None => {
            let mut b = [0u8; 24];
            getrandom_fill(&mut b)?;
            b.iter().map(|x| format!("{x:02x}")).collect()
        }
    };
    // Keep the rest of the listener's settings (allowed origins and hosts,
    // `tokenRotated`); a token made here is new, so it never rotates.
    let mut websocket =
        cfg.get("websocket").cloned().filter(Value::is_object).unwrap_or_else(|| json!({}));
    websocket["listen"] = json!(format!("127.0.0.1:{port}"));
    websocket["token"] = json!(token);
    if kept.is_none() {
        websocket["tokenRotated"] = json!(1);
    }
    cfg["websocket"] = websocket;
    if cfg.get("store").is_none() {
        cfg["store"] = json!({"mode": "local"});
    }
    if cfg.get("permissionPolicy").is_none() {
        cfg["permissionPolicy"] = json!("ask");
    }
    let cfg_text = serde_json::to_string_pretty(&cfg)?;
    // The config holds the WebSocket token: owner-only, whatever the umask.
    ssh(
        host,
        &format!(
            "chmod 700 ~/.acpmux && umask 077 && cat > ~/.acpmux/config.json <<'ACPMUX_CFG' && chmod 600 ~/.acpmux/config.json\n{cfg_text}\nACPMUX_CFG"
        ),
    )?;
    let os = ssh(host, "uname -s")?;
    let status = if os == "Darwin" {
        let home = ssh(host, "echo $HOME")?;
        let plist = PLIST.replace("__HOME__", &home);
        ssh(
            host,
            &format!(
                "mkdir -p ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/com.acpmux.daemon.plist <<'ACPMUX_PLIST'\n{plist}\nACPMUX_PLIST\nlaunchctl bootout gui/$(id -u)/com.acpmux.daemon 2>/dev/null || true; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.acpmux.daemon.plist"
            ),
        )?;
        std::thread::sleep(LAUNCHD_START_GRACE);
        launchd_status(host, false)?
    } else {
        ssh(host, &restart_detached(false))?
    };
    // Register (or re-register) the peer.
    let url = if port == 47811 { format!("ssh://{host}") } else { format!("ssh://{host}:{port}") };
    // Always with the url: a known peer takes the host and port given now.
    let peers = connect_peer(&client, &name, Some(url.as_str())).await?;
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
            let host = ssh_host(p.get("url").and_then(Value::as_str)?)?;
            Some((n.to_owned(), host))
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
    let mut peers = json!({});
    for row in rows.iter().filter(|r| r.get("ok") == Some(&json!(true))) {
        let name = row.get("peer").and_then(Value::as_str).unwrap_or_default();
        peers = connect_peer(&client, name, None).await?;
    }
    if peers.get("peers").is_none() {
        peers = client.request("_acpmux/peers", json!({})).await?;
    }
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

/// The ssh host of an `ssh://host[:port]` peer url. As in `Peer::ssh_parts`,
/// only a numeric suffix is a port, so a bracketed IPv6 host stays whole.
fn ssh_host(url: &str) -> Option<String> {
    crate::peer::ssh_target(url).ok().map(|t| t.destination)
}

/// Fill `buf` from /dev/urandom; a failure aborts setup rather than writing
/// a weak token.
fn getrandom_fill(buf: &mut [u8]) -> Result<()> {
    use std::io::Read;
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(buf))
        .context("read /dev/urandom for the WebSocket token")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_ssh_and_scp_argv_puts_double_dash_before_the_destination() {
        let check = |argv: Vec<String>, dest: &str| {
            let dd = argv.iter().position(|a| a == "--").expect("a --");
            assert!(argv[dd + 1..].iter().any(|a| a.starts_with(dest)), "{argv:?}");
            assert!(argv[..dd].iter().all(|a| !a.contains(dest)), "{argv:?}");
        };
        check(super::ssh_argv("me@box", "true").unwrap(), "me@box");
        check(super::scp_push_argv("box", "/bin/acpmux", ".local/x").unwrap(), "box");
        check(super::scp_fetch_argv("ssh://box:2222", "/tmp/b.tar", "/l").unwrap(), "box:");
    }

    #[test]
    fn option_shaped_hosts_and_odd_bundle_paths_are_refused() {
        for bad in ["-oProxyCommand=touch /tmp/x", "-F", "-luser@box", "ho st", "box\n", "box:22"] {
            assert!(super::ssh_argv(bad, "true").is_err(), "{bad:?}");
            assert!(super::scp_push_argv(bad, "/x", "y").is_err(), "{bad:?}");
        }
        assert!(super::scp_fetch_argv("ssh://-oProxyCommand=x", "/b", "/l").is_err());
        for path in ["/b; rm -rf ~", "$(id)", "relative", "/b c", "-oX"] {
            assert!(super::scp_fetch_argv("ssh://box", path, "/l").is_err(), "{path:?}");
        }
    }

    #[test]
    fn ssh_host_strips_only_a_numeric_port() {
        assert_eq!(ssh_host("ssh://box").as_deref(), Some("box"));
        assert_eq!(ssh_host("ssh://me@box:47812").as_deref(), Some("me@box"));
        assert_eq!(ssh_host("ssh://[::1]").as_deref(), Some("[::1]"));
        assert_eq!(ssh_host("ssh://[::1]:47812").as_deref(), Some("[::1]"));
        assert_eq!(ssh_host("ws://box:1"), None);
    }
}
