//! `acpmux host setup` and `host update`: install or refresh the daemon on
//! a machine reached over ssh, then register it as a peer. macOS remotes
//! get a launchd agent, Linux remotes the user systemd unit `acpmux.service`,
//! and a host without a user systemd manager a detached start.

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
/// Only the file goes (`self_command.rs`'s executable); no subcommand runs
/// here, so no prefix: the remote copy is named `acpmux`, which cmux-tui
/// runs as acpmux by its argv0, and its own daemon then needs none.
fn push_binary(host: &str) -> Result<String> {
    let exe = crate::self_command::SelfCommand::current()?.exe;
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

/// The user systemd unit a Linux host runs its daemon under: one daemon per
/// user, at `~/.acpmux` (cmuxterm-hq plans/cmux-next/acpmux-one-daemon.md).
/// `KillMode=process`: a stop or restart signals the daemon alone, whose
/// SIGTERM leaves the hosted agents running for the next daemon to adopt;
/// the default (`control-group`) would end every agent host with it. The
/// start limit (5 in 60 s, above `RestartSec=3`'s 20) stops a unit whose
/// daemon cannot take the lock from retrying forever.
const SYSTEMD_UNIT: &str = "[Unit]
Description=acpmux daemon
After=default.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
Environment=PATH=%h/.local/bin:%h/.bun/bin:%h/.cargo/bin:%h/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=%h/.local/bin/acpmux daemon run
WorkingDirectory=%h
Restart=on-failure
RestartSec=3
KillMode=process
TimeoutStopSec=30

[Install]
WantedBy=default.target
";

/// What a Linux script prints when systemd (re)started the daemon: it has
/// no readiness callback there, so the caller reads the status after a grace.
const SYSTEMD_STARTED: &str = "ACPMUX_SYSTEMD_STARTED";

/// Refuses (exit 3, the unit named on stderr) when the running daemon (its
/// pid from `daemon status`) runs under an acpmux systemd unit other than
/// `acpmux.service`, such as a hand-written `acpmux-agent-<host>.service`: a
/// shutdown would end its agents with that unit's cgroup, and the two units
/// would then take turns on the lock. A daemon some other service started
/// (`ssh.service`, a CI runner, `tmux.service`) is not refused: it is shut
/// down keeping its agents like a detached one.
const FOREIGN_UNIT_CHECK: &str = r#"p=$(~/.local/bin/acpmux --json daemon status 2>/dev/null | sed -n 's/^ *"pid": *\([0-9][0-9]*\).*/\1/p' | head -1); u=
if [ -n "$p" ] && [ -r "/proc/$p/cgroup" ]; then u=$(sed -n 's|.*/\(acpmux[^/]*\.service\)$|\1|p' "/proc/$p/cgroup" | head -1); fi
if [ -n "$u" ] && [ "$u" != acpmux.service ]; then echo "the daemon of ~/.acpmux runs under the systemd unit $u: stop and disable it (systemctl --user disable --now $u), then run this again" >&2; exit 3; fi
"#;

/// Whether a user systemd manager answers in this ssh session.
const SYSTEMD_MANAGER: &str = "systemctl --user show-environment >/dev/null 2>&1";

/// Whether the user's systemd manager outlives this ssh session: lingering,
/// asked for when it is not (refused, the detached start, which survives a
/// logout, is kept). Asked only once the unit is known to be used.
const SYSTEMD_LINGERING: &str = r#"{ [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = yes ] || loginctl enable-linger >/dev/null 2>&1; }"#;

/// Fails (exit 4) when the daemon still answers after its shutdown (a live
/// daemon's status carries its `pid`; a stopped one's only `"running":
/// false`): it holds the lock, so the unit's daemon could not take over.
const STILL_RUNNING_CHECK: &str = r#"if ~/.local/bin/acpmux --json daemon status 2>/dev/null | grep -q '"pid": *[0-9]'; then echo "the daemon of ~/.acpmux did not shut down, so acpmux.service cannot take over: stop it, then run this again" >&2; exit 4; fi"#;

/// (Re)start the daemon on a Linux host. Under the user systemd unit
/// `acpmux.service` when the user manager outlives the session
/// ([`SYSTEMD_LINGERING`]): `install` writes the unit first; without it, a
/// host whose unit is missing gets the detached restart. A running unit
/// restarts (SIGTERM, agents kept); otherwise a daemon started another way is
/// shut down keeping its agents ([`STILL_RUNNING_CHECK`] when it stays up)
/// and the unit starts, so one daemon serves the home; a unit that fails to
/// start falls back to the detached start. A daemon under another acpmux unit
/// is refused first ([`FOREIGN_UNIT_CHECK`]).
fn linux_restart(install: bool, json: bool) -> String {
    let unit = if install {
        format!(
            "mkdir -p ~/.config/systemd/user && cat > ~/.config/systemd/user/acpmux.service <<'ACPMUX_UNIT' && systemctl --user daemon-reload &&\n{SYSTEMD_UNIT}ACPMUX_UNIT\n"
        )
    } else {
        String::new()
    };
    let has_unit = format!("{{ {unit}systemctl --user cat acpmux.service >/dev/null 2>&1; }}");
    // Setup asks for linger before it writes the unit; an update only on a
    // host whose unit is already there.
    let usable = if install {
        format!("{SYSTEMD_MANAGER} && {SYSTEMD_LINGERING} && {has_unit}")
    } else {
        format!("{SYSTEMD_MANAGER} && {has_unit} && {SYSTEMD_LINGERING}")
    };
    let detached = restart_detached(json);
    format!(
        "{FOREIGN_UNIT_CHECK}if {usable}; then
if systemctl --user is-active --quiet acpmux.service; then systemctl --user restart acpmux.service && echo {SYSTEMD_STARTED}
else {SHUTDOWN_KEEPING_AGENTS}; {STILL_RUNNING_CHECK}
if systemctl --user enable --now acpmux.service; then echo {SYSTEMD_STARTED}; else {detached}; fi; fi
else {detached}; fi"
    )
}

/// The status after a Linux (re)start: read after a grace when systemd started it.
fn linux_status(host: &str, out: String, json: bool) -> Result<String> {
    if out.lines().any(|l| l.trim() == SYSTEMD_STARTED) {
        std::thread::sleep(LAUNCHD_START_GRACE);
        return launchd_status(host, json);
    }
    Ok(out)
}

/// (Re)start the remote daemon: launchd on macOS, the user systemd unit or a
/// detached start elsewhere.
fn restart_daemon(host: &str) -> Result<String> {
    let os = ssh(host, "uname -s")?;
    if os != "Darwin" {
        let out = ssh(host, &linux_restart(false, true))?;
        return linux_status(host, out, true);
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
        let out = ssh(host, &linux_restart(true, false))?;
        linux_status(host, out, false)?
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

    /// A Linux host as the fake `systemctl` and `loginctl` answer.
    #[derive(Clone, Copy)]
    struct LinuxHost {
        /// A user systemd manager answers.
        manager: bool,
        /// `loginctl show-user -p Linger`; `enable-linger` succeeds when `linger_allowed`.
        linger: bool,
        linger_allowed: bool,
        /// `acpmux.service` runs.
        active: bool,
        /// `enable --now` succeeds.
        enables: bool,
        /// `restart` succeeds.
        restarts: bool,
        /// `acpmux.service` is installed before the run (a host set up earlier).
        installed: bool,
        /// A daemon of `~/.acpmux` runs, in this user unit's cgroup, or at this
        /// cgroup path when it starts with `/` (`None`: none runs).
        daemon_unit: Option<&'static str>,
        /// That daemon is still up after `daemon shutdown`.
        survives_shutdown: bool,
    }

    const LINGERING: LinuxHost = LinuxHost {
        manager: true,
        linger: true,
        linger_allowed: true,
        active: false,
        enables: true,
        restarts: true,
        installed: false,
        daemon_unit: None,
        survives_shutdown: false,
    };

    struct LinuxRun {
        calls: Vec<String>,
        unit: String,
        out: String,
        err: String,
        code: Option<i32>,
    }

    /// `linux_restart(install, true)` in a fake home on `host`.
    #[cfg(unix)]
    fn linux_restart_run(tag: &str, install: bool, host: LinuxHost) -> LinuxRun {
        use std::os::unix::fs::PermissionsExt;
        let home = std::env::temp_dir().join(format!("acpmux-lx-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let bin = home.join(".local/bin");
        std::fs::create_dir_all(&bin).unwrap();
        let fake = |name: &str, body: &str| {
            let file = bin.join(name);
            std::fs::write(
                &file,
                format!("#!/bin/sh\necho \"{name} $*\" >> \"$HOME/calls\"\n{body}\n"),
            )
            .unwrap();
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        };
        let code = |ok: bool| if ok { "exit 0" } else { "exit 1" };
        // The daemon answers `daemon status` until a shutdown it does not survive.
        let daemon = format!(
            "case \"$*\" in \"--json daemon status\") if {} && [ ! -f \"$HOME/stopped\" ]; then printf '{{\\n  \"version\": \"0.1.0\",\\n  \"pid\": 4242,\\n  \"ready\": true\\n}}\\n'; else printf '{{\\n  \"running\": false\\n}}\\n'; fi;; \"daemon shutdown\"*) {};; esac; exit 0",
            if host.daemon_unit.is_some() { "true" } else { "false" },
            if host.survives_shutdown { ":" } else { "touch \"$HOME/stopped\"" },
        );
        fake("acpmux", &daemon);
        fake(
            "systemctl",
            &format!(
                "case \"$2\" in show-environment) {};; cat) test -f \"$HOME/.config/systemd/user/$3\";; is-active) {};; enable) {};; restart) {};; *) exit 0;; esac",
                code(host.manager),
                if host.active { "exit 0" } else { "exit 3" },
                code(host.enables),
                code(host.restarts),
            ),
        );
        fake(
            "loginctl",
            &format!(
                "case \"$1\" in show-user) echo {};; enable-linger) {};; esac",
                if host.linger { "yes" } else { "no" },
                code(host.linger_allowed),
            ),
        );
        if host.installed {
            let dir = home.join(".config/systemd/user");
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("acpmux.service"), SYSTEMD_UNIT).unwrap();
        }
        if let Some(unit) = host.daemon_unit {
            std::fs::create_dir_all(home.join("proc/4242")).unwrap();
            std::fs::write(
                home.join("proc/4242/cgroup"),
                match unit.strip_prefix('/') {
                    Some(path) => format!("0::/{path}\n"),
                    None => format!(
                        "0::/user.slice/user-1001.slice/user@1001.service/app.slice/{unit}\n"
                    ),
                },
            )
            .unwrap();
        }
        let script = linux_restart(install, true)
            .replace("/proc/", &format!("{}/", home.join("proc").display()));
        let out = std::process::Command::new("sh")
            .args(["-c", &script])
            .env("HOME", &home)
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .output()
            .unwrap();
        let calls = std::fs::read_to_string(home.join("calls")).unwrap_or_default();
        let unit = std::fs::read_to_string(home.join(".config/systemd/user/acpmux.service"))
            .unwrap_or_default();
        let _ = std::fs::remove_dir_all(&home);
        LinuxRun {
            calls: calls.lines().map(str::to_owned).collect(),
            unit,
            out: String::from_utf8_lossy(&out.stdout).into_owned(),
            err: String::from_utf8_lossy(&out.stderr).into_owned(),
            code: out.status.code(),
        }
    }

    impl LinuxRun {
        fn started_by_systemd(&self) -> bool {
            self.out.lines().any(|l| l == SYSTEMD_STARTED)
        }
        fn detached_start(&self) -> bool {
            self.calls.iter().any(|c| c == "acpmux --json daemon start")
        }
    }

    #[test]
    #[cfg(unix)]
    fn linux_setup_installs_the_unit_and_hands_a_detached_daemon_to_it() {
        let run = linux_restart_run("setup", true, LINGERING);
        assert_eq!(run.unit, SYSTEMD_UNIT);
        assert!(run.unit.contains("KillMode=process"), "a restart must keep the agent hosts");
        assert!(run.unit.contains("Restart=on-failure"), "a deliberate shutdown stays down");
        let steps: Vec<&str> = run
            .calls
            .iter()
            .map(String::as_str)
            .filter(|c| {
                !c.starts_with("systemctl --user show-environment")
                    && !c.starts_with("loginctl")
                    && *c != "acpmux --json daemon status"
            })
            .collect();
        assert_eq!(
            steps,
            [
                "systemctl --user daemon-reload",
                "systemctl --user cat acpmux.service",
                "systemctl --user is-active --quiet acpmux.service",
                "acpmux daemon shutdown --keep-agents",
                "systemctl --user enable --now acpmux.service",
            ]
        );
        assert!(run.started_by_systemd());
    }

    #[test]
    #[cfg(unix)]
    fn linux_update_restarts_a_running_unit_and_never_starts_a_second_daemon() {
        let run = linux_restart_run("update-active", true, LinuxHost { active: true, ..LINGERING });
        assert!(run.calls.contains(&"systemctl --user restart acpmux.service".to_owned()));
        assert!(
            !run.calls
                .iter()
                .any(|c| c.starts_with("acpmux ") && c != "acpmux --json daemon status"),
            "{:?}",
            run.calls
        );
        assert!(run.started_by_systemd());
    }

    #[test]
    #[cfg(unix)]
    fn linux_falls_back_to_the_detached_start_without_a_unit_a_manager_or_linger() {
        // An update on a host set up before the unit: no unit file.
        let run = linux_restart_run("no-unit", false, LINGERING);
        assert!(run.detached_start() && !run.started_by_systemd(), "{:?}", run.calls);
        assert!(
            !run.calls.iter().any(|c| c.starts_with("loginctl")),
            "an update that does not use the unit leaves linger alone: {:?}",
            run.calls
        );
        // A container without a user manager, even at setup.
        let run = linux_restart_run("no-manager", true, LinuxHost { manager: false, ..LINGERING });
        assert!(run.unit.is_empty() && run.detached_start());
        // No linger and none allowed: the unit would stop at logout.
        let host = LinuxHost { linger: false, linger_allowed: false, ..LINGERING };
        let run = linux_restart_run("no-linger", true, host);
        assert!(run.unit.is_empty() && run.detached_start(), "{:?}", run.calls);
        // Linger off but allowed: turned on, and the unit is used.
        let run = linux_restart_run("linger-on", true, LinuxHost { linger: false, ..LINGERING });
        assert!(run.calls.contains(&"loginctl enable-linger".to_owned()));
        assert!(run.started_by_systemd());
        // A unit that does not start: the detached start, so a daemon runs.
        let run =
            linux_restart_run("enable-fails", true, LinuxHost { enables: false, ..LINGERING });
        assert!(run.detached_start() && !run.started_by_systemd(), "{:?}", run.calls);
    }

    #[test]
    #[cfg(unix)]
    fn a_daemon_under_another_unit_is_refused_before_anything_stops_it() {
        let host = LinuxHost { daemon_unit: Some("acpmux-agent-huge-blue.service"), ..LINGERING };
        for (tag, install) in [("foreign-setup", true), ("foreign-update", false)] {
            let run = linux_restart_run(tag, install, host);
            assert_eq!(run.code, Some(3));
            assert!(run.err.contains("acpmux-agent-huge-blue.service"), "{}", run.err);
            assert_eq!(run.calls, ["acpmux --json daemon status"], "nothing else may run");
            assert!(run.unit.is_empty());
        }
        // The daemon under acpmux.service itself, in a session scope, or in a
        // service that merely started it: no refusal; it is handed to the unit.
        for unit in [
            "acpmux.service",
            "session-4.scope",
            "tmux.service",
            "/system.slice/ssh.service",
            "/system.slice/actions.runner.manaflow-ai.huge-blue.service",
        ] {
            let run = linux_restart_run(
                "own-unit",
                true,
                LinuxHost { daemon_unit: Some(unit), ..LINGERING },
            );
            assert!(run.started_by_systemd(), "{unit}: {}", run.err);
        }
    }

    #[test]
    #[cfg(unix)]
    fn linux_update_of_a_host_set_up_earlier_restarts_its_unit() {
        let host = LinuxHost { installed: true, active: true, ..LINGERING };
        let run = linux_restart_run("update-installed", false, host);
        assert!(run.calls.contains(&"systemctl --user restart acpmux.service".to_owned()));
        assert!(run.started_by_systemd() && !run.detached_start(), "{:?}", run.calls);
        // The restart fails: an error, not a started daemon.
        let run = linux_restart_run("restart-fails", false, LinuxHost { restarts: false, ..host });
        assert_ne!(run.code, Some(0));
        assert!(!run.started_by_systemd() && !run.detached_start(), "{:?}", run.calls);
    }

    #[test]
    #[cfg(unix)]
    fn a_daemon_that_outlives_its_shutdown_fails_the_handoff_instead_of_looping_the_unit() {
        let host = LinuxHost {
            installed: true,
            daemon_unit: Some("session-4.scope"),
            survives_shutdown: true,
            ..LINGERING
        };
        let run = linux_restart_run("survives", false, host);
        assert_eq!(run.code, Some(4), "{}", run.err);
        assert!(run.err.contains("did not shut down"), "{}", run.err);
        assert!(
            !run.calls.iter().any(|c| c.starts_with("systemctl --user enable")),
            "the unit must not start against a held lock: {:?}",
            run.calls
        );
        assert!(!run.started_by_systemd() && !run.detached_start());
        assert!(SYSTEMD_UNIT.contains("StartLimitBurst="), "a lock-held unit gives up");
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
