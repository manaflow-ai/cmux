//! `acpmux host setup` and `host update`: install or refresh the daemon on
//! a machine reached over ssh, then register it as a peer. macOS remotes
//! get a launchd agent, Linux remotes the user systemd unit `acpmux.service`,
//! and a host without a user systemd manager a detached start. The update's
//! checks and rollback are in `host_update.rs`; the scripts both run are here,
//! the move of a daemon from a hand-written unit to `acpmux.service` is in
//! `host_migrate.rs`, and the lock that keeps two updates of one host apart
//! in `host_lock.rs`.

use crate::cli::output::print_json;
use crate::client::Client;
use crate::no_panic::JsonExt;
use anyhow::{Context, Result, anyhow};
use cmux_server_core::units::LaunchdJob;
use serde_json::{Value, json};
use std::io::Write;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;

#[cfg(test)]
#[path = "host_launchd_tests.rs"]
mod host_launchd_tests;
#[path = "host_lock.rs"]
mod host_lock;
#[path = "host_migrate.rs"]
mod host_migrate;
#[path = "host_update.rs"]
mod host_update;
#[cfg(test)]
pub(crate) use host_lock::unfence;
pub(crate) use host_lock::{LockLost, lock_to_install, lock_updates};
use host_migrate::{MIGRATING, REFUSED, migrate, migrate_back};
pub(crate) use host_update::{Caller, UpdateOptions, update};

/// Where `host setup` installs acpmux and what its daemon runs.
pub(crate) const DAEMON_BIN: &str = "~/.local/bin/acpmux";

/// The acpmux home on a remote ssh host, as a remote shell path: the
/// default home its standalone daemon and a shipped cmux use there (this
/// machine's own home comes from its resolver, `config.rs`).
pub(crate) const REMOTE_HOME: &str = "~/.acpmux";

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
    /// Start one of acpmux's fixed scripts on the host and leave it running,
    /// its stdin, stdout and stderr piped: [`lock_updates`] holds the host's
    /// update lock with it.
    fn spawn(&self, script: &str) -> Result<Child>;
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

    fn spawn(&self, script: &str) -> Result<Child> {
        Command::new("ssh")
            .args(ssh_argv(self.0, script)?)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("ssh {}", self.0))
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
    let command = posix_command(script);
    Ok(["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", host, command.as_str()]
        .iter()
        .map(|s| s.to_string())
        .collect())
}

/// What ssh hands the remote login shell: `script` run by `/bin/sh`, so it means the same
/// under zsh (the macOS default, where an unmatched glob aborts the command), bash or fish.
const POSIX_PREFIX: &str = "exec /bin/sh -c '";

fn posix_command(script: &str) -> String {
    format!("{POSIX_PREFIX}{}'", script.replace('\'', "'\\''"))
}

/// The script inside an [`ssh_argv`] command string (the tests' fake ssh reads it).
#[cfg(test)]
pub(crate) fn script_of(command: &str) -> Option<String> {
    let quoted = command.strip_prefix(POSIX_PREFIX)?.strip_suffix('\'')?;
    Some(quoted.replace("'\\''", "'"))
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
/// The caller holds the host's update lock and passes `r` fenced for it
/// ([`lock_updates`]).
/// Only the file goes (`self_command.rs`'s executable); no subcommand runs
/// here, so no prefix: a copy named `acpmux` runs as acpmux by its argv0
/// (cmux-tui's too), and [`version_cmd`] gives another name its `acp`.
pub(crate) fn push_binary(r: &dyn Remote, bin: &str) -> Result<String> {
    if !plain_path(bin) {
        return Err(anyhow!("refusing that remote binary path (not a plain path)"));
    }
    let exe = crate::self_command::SelfCommand::current()?.exe;
    let dir = bin.rsplit_once('/').map(|(d, _)| d).filter(|d| !d.is_empty()).unwrap_or("/");
    run(r, &format!("mkdir -p {dir} {REMOTE_HOME}"))?;
    r.push(&exe, &format!("{bin}.new"))?;
    run(r, &format!("rm -f {bin} && mv {bin}.new {bin} && chmod +x {bin} && {}", version_cmd(bin)))
}

/// `host update`'s push: copy `local` to the remote [`DAEMON_BIN`] (by a
/// rename, never in place: macOS kills a running binary that is
/// overwritten); answers the new binary's `--version`. The copy runs as
/// acpmux by its argv0 (cmux-tui's too), so it waits as `.acpmux-new/acpmux`,
/// the same name, while it is checked ([`INSTALL_PUSHED`]).
fn push_update(r: &dyn Remote, local: &Path) -> Result<String> {
    run(
        r,
        "mkdir -p ~/.local/bin ~/.acpmux && rm -rf ~/.local/bin/.acpmux-new ~/.local/bin/acpmux.new && mkdir ~/.local/bin/.acpmux-new",
    )?;
    r.push(local, "~/.local/bin/.acpmux-new/acpmux")?;
    run(r, INSTALL_PUSHED)
}

/// Install the pushed `.acpmux-new/acpmux` once its `--version` runs (else
/// delete it and leave the installed binary alone), keeping the binary it
/// replaces as `acpmux.prev` (a hard link, else a copy; none when nothing
/// was installed, so a rollback never brings back an older one) for a
/// rollback. The rename swaps the two in one step; prints the new binary's
/// version. Once it is in place nothing fails the install: a staging folder
/// that will not go is left for the next push to clear.
const INSTALL_PUSHED: &str = "cd ~/.local/bin && chmod +x .acpmux-new/acpmux && { v=$(.acpmux-new/acpmux --version) || { rm -rf .acpmux-new; echo 'the pushed acpmux does not run on this host' >&2; exit 1; }; } && { if [ -e acpmux ]; then ln -f acpmux acpmux.prev 2>/dev/null || cp -p acpmux acpmux.prev; else rm -f acpmux.prev; fi; } && mv -f .acpmux-new/acpmux acpmux && { rmdir .acpmux-new 2>/dev/null; printf '%s\\n' \"$v\"; }";

/// Put `acpmux.prev` back as `~/.local/bin/acpmux`; fails without one.
const RESTORE_PREV: &str = "(cd ~/.local/bin && [ -f acpmux.prev ] && rm -f acpmux && { ln acpmux.prev acpmux 2>/dev/null || cp -p acpmux.prev acpmux; })";

/// The daemon's launchd agent; `__HOME__` and `__PROCESS_TYPE__` are filled
/// in by [`launchd_plist`].
const PLIST: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.acpmux.daemon</string>
  <key>ProgramArguments</key><array><string>__HOME__/.local/bin/acpmux</string><string>daemon</string><string>run</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>__HOME__/.local/bin:__HOME__/.bun/bin:__HOME__/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string><key>HOME</key><string>__HOME__</string></dict>
  <key>WorkingDirectory</key><string>__HOME__</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>__PROCESS_TYPE__</string>
  <key>StandardOutPath</key><string>__HOME__/.acpmux/launchd.log</string>
  <key>StandardErrorPath</key><string>__HOME__/.acpmux/launchd.log</string>
</dict></plist>
"#;

/// The daemon's agent plist for a host whose `$HOME` is `home`, at the
/// process-roles table's `ProcessType` (threading-model.md "Process
/// roles"): the agent sessions a person prompts and watches run in it, so
/// launchd must not throttle it as a `Background` or default (`Standard`) job.
fn launchd_plist(home: &str) -> String {
    PLIST
        .replace("__HOME__", home)
        .replace("__PROCESS_TYPE__", LaunchdJob::AcpmuxDaemon.process_type())
}

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

/// (Re)start the launchd daemon from its plist: `bootout`, wait for the old
/// process to exit, then `bootstrap`. Never `kickstart -k`: on macOS 27, once
/// the binary at the plist's path is a new ad-hoc signed build (a new code
/// identifier), launchd kills the restarted process at once
/// (`OS_REASON_CODESIGNING`), while a fresh bootstrap runs it. A job that is
/// not loaded fails `bootout` harmlessly and is bootstrapped all the same.
/// `bootout` sends SIGTERM (the daemon leaves its agent hosts running for the
/// next one to adopt) and may return before the process has exited; a daemon
/// started then would find `daemon.lock` held and exit. So the old pid, read
/// from `launchctl print`, is waited on for at most 30 s (launchd SIGKILLs a
/// job after its 20 s `ExitTimeOut`); the bootstrap runs after the deadline
/// in any case. Fails when the bootstrap fails. Before the bootstrap,
/// `plutil` sets the plist's `ProcessType` to the [`launchd_plist`] value, so
/// a `host update` of a host that an older acpmux set up (no `ProcessType`)
/// restarts the daemon at its process role.
const LAUNCHD_RELOAD: &str = r#"acpmux_job=gui/$(id -u)/com.acpmux.daemon
acpmux_old=$(launchctl print "$acpmux_job" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' | head -n 1)
launchctl bootout "$acpmux_job" 2>/dev/null || true
if [ -n "$acpmux_old" ]; then acpmux_i=0; while ps -p "$acpmux_old" >/dev/null 2>&1 && [ "$acpmux_i" -lt 150 ]; do sleep 0.2; acpmux_i=$((acpmux_i+1)); done; fi
plutil -replace ProcessType -string Interactive ~/Library/LaunchAgents/com.acpmux.daemon.plist 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.acpmux.daemon.plist"#;

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

/// Sets `$p` to the running daemon's pid (from `daemon status`) and `$u` to
/// the acpmux systemd unit it runs under, if any. A daemon some other service
/// started (`ssh.service`, a CI runner, `tmux.service`) has no `$u`: it is
/// shut down keeping its agents like a detached one.
const DAEMON_UNIT: &str = r#"p=$(~/.local/bin/acpmux --json daemon status 2>/dev/null | sed -n 's/^ *"pid": *\([0-9][0-9]*\).*/\1/p' | head -1); u=
if [ -n "$p" ] && [ -r "/proc/$p/cgroup" ]; then u=$(sed -n 's|.*/\(acpmux[^/]*\.service\)$|\1|p' "/proc/$p/cgroup" | head -1); fi
"#;

/// Setup refuses (exit 3, the unit named on stderr) a daemon under an acpmux
/// unit other than `acpmux.service`, such as a hand-written
/// `acpmux-agent-<host>.service`: a shutdown would end its agents with that
/// unit's cgroup, and the two units would then take turns on the lock. An
/// update moves it instead ([`migrate`]).
const FOREIGN_UNIT_REFUSAL: &str = r#"if [ -n "$u" ] && [ "$u" != acpmux.service ]; then echo "the daemon of ~/.acpmux runs under the systemd unit $u: stop and disable it (systemctl --user disable --now $u), then run this again" >&2; exit 3; fi
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
/// is refused first at setup ([`FOREIGN_UNIT_REFUSAL`]) and moved to
/// `acpmux.service` by an update ([`migrate`]).
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
    let foreign = if install { FOREIGN_UNIT_REFUSAL.to_owned() } else { migrate(false) };
    format!(
        "{DAEMON_UNIT}{foreign}if {usable}; then
if systemctl --user is-active --quiet acpmux.service; then systemctl --user restart acpmux.service && echo {SYSTEMD_STARTED}
else {SHUTDOWN_KEEPING_AGENTS}; {STILL_RUNNING_CHECK}
if systemctl --user enable --now acpmux.service; then echo {SYSTEMD_STARTED}; else {detached}; fi; fi
else {detached}; fi"
    )
}

/// The status after a Linux (re)start: read after a grace when systemd started it.
fn linux_status(r: &dyn Remote, out: String, json: bool) -> Result<String> {
    if out.lines().any(|l| l.trim() == SYSTEMD_STARTED) {
        std::thread::sleep(LAUNCHD_START_GRACE);
        return launchd_status(r, json);
    }
    Ok(out)
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

/// The peer url of an ssh host whose daemon listens on `port`: the port
/// only when it is not the default.
pub(crate) fn ssh_peer_url(host: &str, port: u16) -> String {
    if port == crate::peer::SSH_PEER_PORT {
        format!("ssh://{host}")
    } else {
        format!("ssh://{host}:{port}")
    }
}

/// The peer name a host gets by default: its first label, without `user@`.
pub(crate) fn short_name(host: &str) -> String {
    host.split('@').next_back().unwrap_or(host).split('.').next().unwrap_or(host).to_owned()
}

/// `host setup`, holding the host's update lock while it installs.
pub(crate) async fn setup(
    client: Arc<Client>,
    host: &str,
    name: Option<String>,
    port: u16,
    json_out: bool,
) -> Result<()> {
    let name = name.unwrap_or_else(|| short_name(host));
    let ssh = SshRemote(host);
    let lock = lock_to_install(&ssh)?;
    let remote = lock.fence(&ssh);
    let version = push_binary(&remote, DAEMON_BIN)?;
    let status = install_daemon(&remote, port, false)?;
    drop(lock);
    // Register (or re-register) the peer.
    let url = ssh_peer_url(host, port);
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

/// The daemon config `install_daemon` writes, from the host's `existing`
/// one: every setting kept, the WebSocket listener on `127.0.0.1:port`, its
/// token kept, else `fresh` with `tokenRotated` 1 (a token made here is new,
/// so it never rotates); the listener's other keys (allowed origins and
/// hosts, `tokenRotated`) stay. A store and permission policy only when
/// missing.
fn daemon_config(existing: &str, port: u16, fresh: &str) -> Value {
    let mut cfg: Value = serde_json::from_str(existing).unwrap_or_else(|_| json!({}));
    if !cfg.is_object() {
        cfg = json!({});
    }
    let kept = cfg.pointer("/websocket/token").and_then(Value::as_str).map(str::to_owned);
    let mut websocket =
        cfg.get("websocket").cloned().filter(Value::is_object).unwrap_or_else(|| json!({}));
    websocket.set("listen", json!(format!("127.0.0.1:{port}")));
    websocket.set("token", json!(kept.clone().unwrap_or_else(|| fresh.to_owned())));
    if kept.is_none() {
        websocket.set("tokenRotated", json!(1));
    }
    cfg.set("websocket", websocket);
    if cfg.get("store").is_none() {
        cfg.set("store", json!({"mode": "local"}));
    }
    if cfg.get("permissionPolicy").is_none() {
        cfg.set("permissionPolicy", json!("ask"));
    }
    cfg
}

/// The fixed script that writes the daemon config from stdin: the config
/// holds the WebSocket token, so it never goes into a command line (ssh's,
/// visible in `ps` here, or the remote shell's), and the file is
/// owner-only whatever the umask, replaced in one rename.
fn config_write_script() -> String {
    format!(
        "mkdir -p {REMOTE_HOME} && chmod 700 {REMOTE_HOME} && umask 077 && cat > {REMOTE_HOME}/config.json.new && chmod 600 {REMOTE_HOME}/config.json.new && mv -f {REMOTE_HOME}/config.json.new {REMOTE_HOME}/config.json"
    )
}

/// Write `cfg_text` as the remote daemon config, over stdin.
fn write_config(r: &dyn Remote, cfg_text: &str) -> Result<()> {
    let out = r.exec(&config_write_script(), Some(cfg_text.as_bytes()))?;
    if !out.ok {
        return Err(anyhow!(
            "writing the daemon config on {} failed: {}",
            r.host(),
            out.stderr.trim()
        ));
    }
    Ok(())
}

/// Configure and (re)start the daemon of the acpmux at [`DAEMON_BIN`]: keep
/// an existing config but make sure the WebSocket listener on `port` and its
/// token exist ([`daemon_config`]), then launchd on macOS, the user systemd
/// unit or a detached start on Linux ([`linux_restart`]). The daemon's
/// status (JSON with `json`). The caller holds the host's update lock and
/// passes `r` fenced for it ([`lock_updates`]).
pub(crate) fn install_daemon(r: &dyn Remote, port: u16, json: bool) -> Result<String> {
    let existing = run(r, &format!("cat {REMOTE_HOME}/config.json 2>/dev/null || echo '{{}}'"))?;
    let mut fresh = [0u8; 24];
    getrandom_fill(&mut fresh)?;
    let fresh: String = fresh.iter().map(|x| format!("{x:02x}")).collect();
    let cfg = daemon_config(&existing, port, &fresh);
    write_config(r, &serde_json::to_string_pretty(&cfg)?)?;
    let os = run(r, "uname -s")?;
    if os != "Darwin" {
        let out = run(r, &linux_restart(true, json))?;
        return linux_status(r, out, json);
    }
    let home = run(r, "echo $HOME")?;
    let plist = launchd_plist(&home);
    run(
        r,
        &format!(
            "mkdir -p ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/com.acpmux.daemon.plist <<'ACPMUX_PLIST'\n{plist}\nACPMUX_PLIST\n{LAUNCHD_RELOAD}"
        ),
    )?;
    std::thread::sleep(LAUNCHD_START_GRACE);
    launchd_status(r, json)
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

    /// What the remote login shell does with ssh's command string: runs it with `-c`.
    fn as_login_shell(shell: &str, argv: &[String]) -> Option<String> {
        let out = std::process::Command::new(shell).arg("-c").arg(argv.last()?).output().ok()?;
        Some(String::from_utf8_lossy(&out.stdout).into_owned())
    }

    #[test]
    fn a_remote_script_runs_the_same_under_zsh_bash_and_sh_login_shells() {
        // macOS logs in with zsh, where an unmatched glob aborts the whole command
        // ("no matches found"): enroll's probe saw no daemon and no config on a Mac
        // without a cmux app. Every script runs under /bin/sh whatever the login shell.
        let script = "for f in /nonexistent-cmux*.app/x; do [ -e \"$f\" ] && echo hit; done; printf 'after %s\\n' \"it's\"";
        let argv = ssh_argv("leo@huge-blue", script).unwrap();
        assert_eq!(
            &argv[..6],
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", "leo@huge-blue"]
        );
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
            if !std::path::Path::new(shell).exists() {
                continue;
            }
            assert_eq!(as_login_shell(shell, &argv).as_deref(), Some("after it's\n"), "{shell}");
        }
        assert_eq!(script_of(&argv[6]).as_deref(), Some(script));
    }

    /// Records each script and its stdin; answers ok with `stdout`.
    struct Recorder(std::cell::RefCell<Vec<(String, Option<Vec<u8>>)>>, &'static str);

    impl Remote for Recorder {
        fn host(&self) -> &str {
            "box"
        }
        fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut> {
            self.0.borrow_mut().push((script.to_owned(), stdin.map(<[u8]>::to_vec)));
            Ok(RemoteOut { ok: true, stdout: self.1.into(), stderr: String::new() })
        }
        fn push(&self, _: &Path, _: &str) -> Result<()> {
            unreachable!()
        }
        fn spawn(&self, _: &str) -> Result<Child> {
            unreachable!()
        }
    }

    #[test]
    fn the_config_and_its_token_go_over_stdin_not_the_command_line() {
        let r = Recorder(Default::default(), "");
        let cfg = daemon_config("{}", 47811, "secret-token-123");
        write_config(&r, &serde_json::to_string_pretty(&cfg).unwrap()).unwrap();
        let calls = r.0.borrow();
        let (script, stdin) = &calls[0];
        assert!(!script.contains("secret-token-123"), "{script}");
        assert_eq!(script, &config_write_script());
        for keep in ["chmod 700", "umask 077", "chmod 600", "cat > "] {
            assert!(script.contains(keep), "{keep}: {script}");
        }
        let stdin = String::from_utf8(stdin.clone().expect("stdin")).unwrap();
        assert!(stdin.contains("secret-token-123"));
    }

    #[test]
    #[cfg(unix)]
    fn the_config_script_writes_an_owner_only_file() {
        use std::os::unix::fs::PermissionsExt;
        let home = std::env::temp_dir().join(format!("acpmux-cfg-write-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let mut child = std::process::Command::new("sh")
            .args(["-c", &config_write_script()])
            .env("HOME", &home)
            .stdin(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        std::io::Write::write_all(&mut child.stdin.take().unwrap(), b"{\"x\":1}\n").unwrap();
        assert!(child.wait().unwrap().success());
        let dir = home.join(REMOTE_HOME.trim_start_matches("~/"));
        let file = dir.join("config.json");
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "{\"x\":1}\n");
        assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn peer_urls_name_a_port_only_off_the_default() {
        assert_eq!(ssh_peer_url("hb", 47811), "ssh://hb");
        assert_eq!(ssh_peer_url("leo@hb", 47900), "ssh://leo@hb:47900");
    }

    #[test]
    fn the_daemon_config_keeps_the_listener_settings_and_marks_a_new_token() {
        let existing = r#"{"websocket":{"listen":"0.0.0.0:1","token":"old","allowedOrigins":["https://a"],"allowedHosts":["h"],"tokenRotated":7},"store":{"mode":"cloud"},"x":1}"#;
        let cfg = daemon_config(existing, 47811, "fresh");
        let ws = &cfg["websocket"];
        assert_eq!(ws["listen"], "127.0.0.1:47811");
        assert_eq!(ws["token"], "old", "an existing token is kept");
        assert_eq!(ws["tokenRotated"], 7, "and its rotation count");
        assert_eq!(ws["allowedOrigins"], json!(["https://a"]));
        assert_eq!(ws["allowedHosts"], json!(["h"]));
        assert_eq!(cfg["store"], json!({"mode": "cloud"}));
        assert_eq!(cfg["x"], 1);
        assert_eq!(cfg["permissionPolicy"], "ask");

        // No token yet: the fresh one, marked rotated once; other keys stay.
        let cfg = daemon_config(r#"{"websocket":{"allowedHosts":["h"]}}"#, 47900, "fresh");
        assert_eq!(cfg["websocket"]["token"], "fresh");
        assert_eq!(cfg["websocket"]["tokenRotated"], 1);
        assert_eq!(cfg["websocket"]["allowedHosts"], json!(["h"]));
        assert_eq!(cfg["websocket"]["listen"], "127.0.0.1:47900");
        assert_eq!(cfg["store"], json!({"mode": "local"}));
        for broken in ["", "not json", "[]"] {
            let cfg = daemon_config(broken, 47811, "fresh");
            assert_eq!(cfg["websocket"]["token"], "fresh", "{broken:?}");
            assert_eq!(cfg["websocket"]["tokenRotated"], 1);
        }
    }

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
