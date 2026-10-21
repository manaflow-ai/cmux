//! `acpmux host setup` and `host update`: install or refresh the daemon on
//! a machine reached over ssh, then register it as a peer. macOS remotes
//! get a launchd agent; others get a nohup fallback.

use crate::cli::output::print_json;
use crate::client::Client;
use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;

/// Where `host setup` installs acpmux and what its daemon runs.
pub(crate) const DAEMON_BIN: &str = "~/.local/bin/acpmux";

/// What a remote command answered.
#[derive(Debug, Clone, Default)]
pub(crate) struct RemoteOut {
    pub ok: bool,
    pub stdout: String,
    pub stderr: String,
}

/// How the host commands reach a machine: ssh, or a fake in tests.
pub(crate) trait Remote {
    fn host(&self) -> &str;
    /// Run one of acpmux's fixed scripts on the host; `stdin` is fed to it
    /// (data never goes into the script text).
    fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut>;
    /// Copy a local file to `remote` (a plain `~/` or absolute path).
    fn push(&self, local: &Path, remote: &str) -> Result<()>;
}

pub(crate) struct SshRemote<'a>(pub &'a str);

impl Remote for SshRemote<'_> {
    fn host(&self) -> &str {
        self.0
    }

    fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut> {
        let mut child = Command::new("ssh")
            .args(ssh_argv(self.0, script)?)
            .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("ssh {}", self.0))?;
        if let (Some(bytes), Some(mut pipe)) = (stdin, child.stdin.take()) {
            pipe.write_all(bytes).with_context(|| format!("ssh {}: stdin", self.0))?;
        }
        let out = child.wait_with_output().with_context(|| format!("ssh {}", self.0))?;
        Ok(RemoteOut {
            ok: out.status.success(),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        })
    }

    fn push(&self, local: &Path, remote: &str) -> Result<()> {
        // scp takes a path without `~/` as one under the remote home.
        let remote = remote.strip_prefix("~/").unwrap_or(remote);
        let status = Command::new("scp")
            .args(scp_push_argv(self.0, &local.to_string_lossy(), remote)?)
            .status()
            .context("scp")?;
        if !status.success() {
            return Err(anyhow!("scp to {} failed", self.0));
        }
        Ok(())
    }
}

/// A plain absolute or home path: safe in a remote shell script unquoted
/// (a `~/` still expands) and as an scp path.
pub(crate) fn plain_path(path: &str) -> bool {
    (path.starts_with('/') || path.starts_with("~/"))
        && path.bytes().all(|b| b.is_ascii_alphanumeric() || b"/._-~+".contains(&b))
}

/// An ssh destination given on the command line or taken from a peer URL,
/// checked like a peer's (`peer::ssh_target`): never an ssh option.
pub(crate) fn checked_host(host: &str) -> Result<&str> {
    let t = crate::peer::ssh_target(&format!("ssh://{host}"))
        .map_err(|why| anyhow!("refusing that ssh host: {why}"))?;
    if t.destination != host {
        return Err(anyhow!("refusing that ssh host: give the host without a port"));
    }
    Ok(host)
}

/// `ssh ... -- HOST SCRIPT`: `--` before the destination; the script is
/// acpmux's own fixed text.
pub(crate) fn ssh_argv(host: &str, script: &str) -> Result<Vec<String>> {
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
    if !plain_path(remote) {
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

/// Run `script` on the host; its trimmed output, or an error with its stderr.
pub(crate) fn run(r: &dyn Remote, script: &str) -> Result<String> {
    let out = r.exec(script, None)?;
    if !out.ok {
        return Err(anyhow!("ssh {} failed: {}", r.host(), out.stderr.trim()));
    }
    Ok(out.stdout.trim().to_owned())
}

fn ssh(host: &str, script: &str) -> Result<String> {
    run(&SshRemote(host), script)
}

/// The remote command that prints `bin`'s version line: a binary named
/// `acpmux` is acpmux; any other (the app's `cmux-tui`) carries it as `acp`.
pub(crate) fn version_cmd(bin: &str) -> String {
    if bin.rsplit('/').next() == Some("acpmux") {
        format!("{bin} --version")
    } else {
        format!("{bin} acp --version")
    }
}

/// Copy this very binary to the remote `bin` (rm then mv, never in place:
/// macOS kills a running binary that is overwritten); its version line.
pub(crate) fn push_binary(r: &dyn Remote, bin: &str) -> Result<String> {
    if !plain_path(bin) {
        return Err(anyhow!("refusing that remote binary path (not a plain path)"));
    }
    let exe = std::env::current_exe()?;
    let dir = bin.rsplit_once('/').map(|(d, _)| d).filter(|d| !d.is_empty()).unwrap_or("/");
    run(r, &format!("mkdir -p {dir} ~/.acpmux"))?;
    r.push(&exe, &format!("{bin}.new"))?;
    run(r, &format!("rm -f {bin} && mv {bin}.new {bin} && chmod +x {bin} && {}", version_cmd(bin)))
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

/// Restart the daemon away from launchd: `daemon shutdown --keep-agents`
/// (hosted agents keep running for the new daemon to adopt) returns once the
/// old daemon released its lock, and `daemon start` returns once the new one
/// accepts clients (its readiness pipe), so no step waits on a timer.
fn restart_detached(json: bool) -> String {
    let start = if json {
        capped("~/.local/bin/acpmux --json daemon start", "head -c 400")
    } else {
        capped("~/.local/bin/acpmux daemon start", "head -3")
    };
    format!("{SHUTDOWN_KEEPING_AGENTS}; {start}")
}

/// `daemon shutdown --keep-agents` on the remote. A CLI older than the flag
/// rejects it (clap's usage error names it); its plain `daemon shutdown`
/// already keeps hosted agents, so only then it runs again without the flag.
/// Any other failure (no daemon runs) is not retried.
const SHUTDOWN_KEEPING_AGENTS: &str = "out=$(~/.local/bin/acpmux daemon shutdown --keep-agents 2>&1) || case \"$out\" in *\"unexpected argument '--keep-agents'\"*) ~/.local/bin/acpmux daemon shutdown >/dev/null 2>&1 ;; esac";

/// Read the daemon's status after launchd (re)started it; a daemon that is
/// still not running is an error, not a status line.
fn launchd_status(r: &dyn Remote, json: bool) -> Result<String> {
    let host = r.host();
    let status = if json {
        run(r, &capped("~/.local/bin/acpmux --json daemon status", "head -c 400"))?
    } else {
        run(r, &capped("~/.local/bin/acpmux daemon status", "head -3"))?
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
    launchd_status(&SshRemote(host), true)
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

/// The peer name a host gets by default: its first label, without `user@`.
pub(crate) fn short_name(host: &str) -> String {
    host.split('@').next_back().unwrap_or(host).split('.').next().unwrap_or(host).to_owned()
}

pub(crate) async fn setup(
    client: Arc<Client>,
    host: &str,
    name: Option<String>,
    port: u16,
    json_out: bool,
) -> Result<()> {
    let name = name.unwrap_or_else(|| short_name(host));
    let remote = SshRemote(host);
    let version = push_binary(&remote, DAEMON_BIN)?;
    let status = install_daemon(&remote, port, false)?;
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

/// Configure and (re)start the daemon of the acpmux at [`DAEMON_BIN`]: keep
/// an existing config but make sure the WebSocket listener on `port` and its
/// token exist, then launchd on macOS, a detached start elsewhere. The
/// daemon's status (JSON with `json`).
pub(crate) fn install_daemon(r: &dyn Remote, port: u16, json: bool) -> Result<String> {
    let existing = run(r, "cat ~/.acpmux/config.json 2>/dev/null || echo '{}'")?;
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
    run(
        r,
        &format!(
            "chmod 700 ~/.acpmux && umask 077 && cat > ~/.acpmux/config.json <<'ACPMUX_CFG' && chmod 600 ~/.acpmux/config.json\n{cfg_text}\nACPMUX_CFG"
        ),
    )?;
    let os = run(r, "uname -s")?;
    if os != "Darwin" {
        return run(r, &restart_detached(json));
    }
    let home = run(r, "echo $HOME")?;
    let plist = PLIST.replace("__HOME__", &home);
    run(
        r,
        &format!(
            "mkdir -p ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/com.acpmux.daemon.plist <<'ACPMUX_PLIST'\n{plist}\nACPMUX_PLIST\nlaunchctl bootout gui/$(id -u)/com.acpmux.daemon 2>/dev/null || true; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.acpmux.daemon.plist"
        ),
    )?;
    std::thread::sleep(LAUNCHD_START_GRACE);
    launchd_status(r, json)
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
        let outcome = push_binary(&SshRemote(&host), DAEMON_BIN)
            .and_then(|v| restart_daemon(&host).map(|s| (v, s)));
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

/// Fill `buf` from the OS random generator; a failure aborts setup rather
/// than writing a weak token.
fn getrandom_fill(buf: &mut [u8]) -> Result<()> {
    getrandom::fill(buf)
        .map_err(|e| anyhow!("the OS random generator for the WebSocket token: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The remote's shutdown step against a fake `~/.local/bin/acpmux` that
    /// logs its arguments and exits as `body` says; the calls it got.
    #[cfg(unix)]
    fn remote_shutdown_calls(tag: &str, body: &str) -> Vec<String> {
        let home = std::env::temp_dir().join(format!("acpmux-rs-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(home.join(".local/bin")).unwrap();
        let fake = home.join(".local/bin/acpmux");
        std::fs::write(&fake, format!("#!/bin/sh\necho \"$*\" >> \"$HOME/calls\"\n{body}\n"))
            .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::process::Command::new("sh")
            .args(["-c", SHUTDOWN_KEEPING_AGENTS])
            .env("HOME", &home)
            .status()
            .unwrap();
        let calls = std::fs::read_to_string(home.join("calls")).unwrap_or_default();
        let _ = std::fs::remove_dir_all(&home);
        calls.lines().map(str::to_owned).collect()
    }

    #[test]
    #[cfg(unix)]
    fn a_restart_keeps_agents_and_falls_back_only_for_a_cli_without_the_flag() {
        // A current CLI: one call, with the flag.
        assert_eq!(remote_shutdown_calls("new", "exit 0"), ["daemon shutdown --keep-agents"]);
        // A CLI older than the flag: clap refuses it; the plain call detaches.
        let old = r#"case "$*" in *--keep-agents*) echo "error: unexpected argument '--keep-agents' found" >&2; exit 2;; esac"#;
        assert_eq!(
            remote_shutdown_calls("old", old),
            ["daemon shutdown --keep-agents", "daemon shutdown"]
        );
        // Any other failure (no daemon answered) is not retried.
        let down = "echo 'acpmux: runtime: daemon not running' >&2; exit 1";
        assert_eq!(remote_shutdown_calls("down", down), ["daemon shutdown --keep-agents"]);
    }
}
