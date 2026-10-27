//! `acpmux host update`: bring ssh peers to this build (or the one for
//! their target in `--binary-dir`), check the restarted daemon answers with
//! it, and roll back what does not. The scripts it runs live in the parent
//! module (`hosts.rs`), the unit migration in `host_migrate.rs`, the lock
//! that keeps two updates of one host apart in `host_lock.rs`; `host
//! self-update` (`host_self_update.rs`) runs the same update on this machine.

use super::host_auto_update::take_auto_update_off;
use super::host_hold::{Holds, holds_path, now_ms};
use super::{
    DAEMON_UNIT, IN_PLACE, LockLost, MIGRATING, REFUSED, RESTORE_PREV, Remote, RemoteOut,
    SshRemote, connect_peer, launchd_reload, linux_restart, lock_updates, migrate, migrate_back,
    push_update, run, ssh_host,
};
use crate::cli::output::print_json;
use crate::client::Client;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Child;
use std::sync::Arc;

#[path = "host_self_update.rs"]
mod host_self_update;
pub(crate) use host_self_update::self_update;

/// Restart the launchd daemon of a macOS host ([`launchd_reload`]: bootout,
/// then bootstrap, never `kickstart -k`; nothing stopped when launchd refuses
/// jobs; in place with no GUI login), then give it
/// [`super::LAUNCHD_START_GRACE`] (2 s) so its status is not read from the old one.
fn launchd_restart() -> String {
    format!("{} && sleep 2", launchd_reload(true))
}

/// Starts every script [`update_peer`] runs. The daemon's home and socket
/// have one source, `acpmux.service` and its drop-ins: a move from a
/// hand-written unit writes them there (`10-migrated.conf`, `host_migrate.rs`:
/// the home unless it is `~/.acpmux` as written, the socket always), and
/// every script reads them back here, as systemd gives them to the daemon.
/// When the unit sets either, the pair replaces what the script inherited; a
/// unit that sets neither leaves the inherited pair. So a status read or a
/// check reaches the daemon the unit runs, from an ssh session and from
/// `acpmux-update.service`, whose own environment has neither. Read again by
/// every script, so a drop-in a move just wrote counts at once.
///
/// `systemctl show -p Environment --value` prints the assignments separated
/// by spaces and quotes one that needs it as a shell would read it
/// (`"ACPMUX_HOME=/srv/agent data"`, `\"`, `\\`, `\$` and `` \` `` inside):
/// `acpmux_word` splits it into words the way `sh` does, quotes anywhere in
/// a word, with no expansion.
const SERVICE_ENV: &str = r#"acpmux_env=$(command -v systemctl >/dev/null 2>&1 && systemctl --user show acpmux.service -p Environment --value 2>/dev/null)
acpmux_char() { acpmux_c=${acpmux_env%"${acpmux_env#?}"}; acpmux_env=${acpmux_env#?}; }
acpmux_word() {
  acpmux_w=; acpmux_q=; acpmux_any=
  while [ -n "$acpmux_env" ]; do
    acpmux_char
    if [ "$acpmux_q" = "'" ]; then
      if [ "$acpmux_c" = "'" ]; then acpmux_q=; else acpmux_w=$acpmux_w$acpmux_c; fi
    elif [ "$acpmux_q" = '"' ]; then
      case $acpmux_c in '"') acpmux_q= ;; '\') acpmux_char; acpmux_w=$acpmux_w$acpmux_c ;; *) acpmux_w=$acpmux_w$acpmux_c ;; esac
    else
      case $acpmux_c in
        ' '|'	') [ -z "$acpmux_any" ] || return 0 ;;
        "'"|'"') acpmux_q=$acpmux_c; acpmux_any=1 ;;
        '\') acpmux_char; acpmux_w=$acpmux_w$acpmux_c; acpmux_any=1 ;;
        *) acpmux_w=$acpmux_w$acpmux_c; acpmux_any=1 ;;
      esac
    fi
  done
  [ -n "$acpmux_any" ]
}
acpmux_set=; acpmux_h=; acpmux_s=
while acpmux_word; do case $acpmux_w in ACPMUX_HOME=?*) acpmux_h=${acpmux_w#ACPMUX_HOME=}; acpmux_set=1 ;; ACPMUX_SOCKET=?*) acpmux_s=${acpmux_w#ACPMUX_SOCKET=}; acpmux_set=1 ;; esac; done
if [ -n "$acpmux_set" ]; then
  unset ACPMUX_HOME ACPMUX_SOCKET
  if [ -n "$acpmux_h" ]; then export ACPMUX_HOME="$acpmux_h"; fi
  if [ -n "$acpmux_s" ]; then export ACPMUX_SOCKET="$acpmux_s"; fi
fi
"#;

/// A host whose every script starts with [`SERVICE_ENV`].
struct ServiceEnv<'a>(&'a dyn Remote);

impl Remote for ServiceEnv<'_> {
    fn host(&self) -> &str {
        self.0.host()
    }

    fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut> {
        self.0.exec(&format!("{SERVICE_ENV}{script}"), stdin)
    }

    fn push(&self, local: &Path, remote: &str) -> Result<()> {
        self.0.push(local, remote)
    }

    fn spawn(&self, script: &str) -> Result<Child> {
        self.0.spawn(script)
    }
}

/// Waits up to 20 s for a daemon to answer, then prints its
/// `--json daemon status` (or the last reply, from none).
const AWAIT_DAEMON: &str = r#"i=0; while :; do s=$(~/.local/bin/acpmux --json daemon status 2>/dev/null); case "$s" in *'"pid":'*) break;; esac; [ "$i" -ge 20 ] && break; i=$((i+1)); sleep 1; done; printf '%s\n' "$s""#;

/// Separates the parts of [`probe_script`]'s output, on a line of its own
/// (after an empty one: a part need not end its last line).
const PROBE_SPLIT: &str = "ACPMUX_PROBE";

/// A cmux Cloud VM has this file. Its daemon runs in a keyed `systemd-run`
/// scope that `cmux link machine update --to-bundled` owns, so `host update`
/// never replaces its binary or restarts it.
const CLOUD_VM_MARK: &str = "/etc/cmux/vm-kind";

/// What [`probe_script`] prints on a cmux Cloud VM ([`CLOUD_VM_MARK`]).
const CLOUD_VM: &str = "ACPMUX_CLOUD_VM";

/// Starts [`probe_script`]'s `uname -sm` line, so a login banner is not read as one.
const UNAME: &str = "ACPMUX_UNAME=";

/// What `host update` reads before it changes anything: `uname -sm` (and
/// whether the host is a cmux Cloud VM), the daemon's status, with `if_idle` its sessions (only from a daemon that
/// runs: `ls` would start one), and whether a hand-written unit it runs
/// under can be moved ([`migrate`], dry).
fn probe_script(if_idle: bool) -> String {
    let ls = if if_idle {
        r#"case "$s" in *'"pid":'*) ~/.local/bin/acpmux --json ls 2>/dev/null;; esac"#
    } else {
        ":"
    };
    format!(
        "echo \"{UNAME}$(uname -sm)\"; [ ! -e {CLOUD_VM_MARK} ] || echo {CLOUD_VM}; echo; echo {PROBE_SPLIT}\ns=$(~/.local/bin/acpmux --json daemon status 2>/dev/null); printf '%s\\n' \"$s\"; echo; echo {PROBE_SPLIT}\n{ls}\necho; echo {PROBE_SPLIT}\n{DAEMON_UNIT}{}",
        migrate(true)
    )
}

/// A peer as [`probe_script`] found it.
#[derive(Debug)]
struct Probe {
    /// `uname -sm`, e.g. `Linux x86_64`.
    uname: String,
    /// The host is a cmux Cloud VM ([`CLOUD_VM_MARK`]).
    cloud_vm: bool,
    /// The running daemon's build; None when none answers.
    build: Option<String>,
    /// Its own sessions that run a turn or wait on a permission (asked
    /// for), but the caller's turn; None when they could not be read.
    busy: Option<Vec<String>>,
    /// Why its hand-written unit cannot be moved: a reason code and a message.
    refused: Option<(String, String)>,
}

impl Probe {
    /// None when the script did not run (ssh failed). The `caller`'s turn
    /// counts only on another daemon than the caller's.
    fn parse(out: &RemoteOut, caller: Option<&Caller>) -> Option<Probe> {
        let mut parts = vec![String::new()];
        for line in out.stdout.lines() {
            if line == PROBE_SPLIT {
                parts.push(String::new());
            } else if let Some(part) = parts.last_mut() {
                part.push_str(line);
                part.push('\n');
            }
        }
        if parts.len() < 4 {
            return None;
        }
        let build = answering_build(&parts[1]);
        let replied = serde_json::from_str::<Value>(parts[1].trim()).is_ok();
        let busy = match (&build, replied) {
            (Some(_), _) => {
                let instance = serde_json::from_str::<Value>(parts[1].trim())
                    .ok()
                    .and_then(|v| v.get("personInstance")?.as_str().map(str::to_owned));
                let own = caller
                    .filter(|c| instance.as_deref() == Some(c.daemon.as_str()))
                    .map(|c| c.session.as_str());
                busy_sessions(&parts[2], own)
            }
            // A daemon that is not running runs no turn.
            (None, true) => Some(Vec::new()),
            (None, false) => None,
        };
        let refused = parts[3].lines().find_map(|l| l.strip_prefix(REFUSED)).map(|code| {
            let why = out.stderr.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or(code);
            (code.to_owned(), why.trim().to_owned())
        });
        let cloud_vm = parts[0].lines().any(|l| l == CLOUD_VM);
        let uname = parts[0].lines().find_map(|l| l.strip_prefix(UNAME)).unwrap_or_default();
        let uname = uname.trim().to_owned();
        Some(Probe { uname, cloud_vm, build, busy, refused })
    }
}

/// The build of the daemon that answered a `--json daemon status` (a live
/// one's reply carries its `pid`; a stopped one's only `"running": false`);
/// None when none answered or the reply is not JSON.
fn answering_build(status: &str) -> Option<String> {
    let v: Value = serde_json::from_str(status.trim()).ok()?;
    v.get("pid").filter(|p| !p.is_null())?;
    Some(v.get("build").and_then(Value::as_str).unwrap_or_default().to_owned())
}

/// The daemon's own sessions (not its peers') that run a turn or wait on a
/// permission, by name, from its `acpmux --json ls`; None when that is not
/// a session list. The turn of the session `caller` (the one this command
/// runs in, on this daemon) does not count: it runs the update and never
/// ends first. A permission it waits on still does.
fn busy_sessions(ls: &str, caller: Option<&str>) -> Option<Vec<String>> {
    let v: Value = serde_json::from_str(ls.trim()).ok()?;
    let busy = v
        .get("sessions")?
        .as_array()?
        .iter()
        .filter(|s| s.get("peer").is_none())
        .filter(|s| {
            let asks = s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0;
            if caller.is_some() && s.get("sessionId").and_then(Value::as_str) == caller {
                return asks;
            }
            asks || !s.get("turn").unwrap_or(&Value::Null).is_null()
                || matches!(s.get("status").and_then(Value::as_str), Some("running" | "waiting"))
        })
        .map(|s| s.get("name").and_then(Value::as_str).unwrap_or("?").to_owned())
        .collect();
    Some(busy)
}

/// The target an `acpmux-<target>` release binary is built for, from an OS
/// and architecture as `uname -sm` or Rust's `std::env::consts` name them.
fn target_triple(os: &str, arch: &str) -> Option<&'static str> {
    match (os, arch) {
        ("Linux" | "linux", "x86_64" | "amd64") => Some("x86_64-unknown-linux-musl"),
        ("Linux" | "linux", "aarch64" | "arm64") => Some("aarch64-unknown-linux-musl"),
        ("Darwin" | "macos", "arm64" | "aarch64") => Some("aarch64-apple-darwin"),
        ("Darwin" | "macos", "x86_64") => Some("x86_64-apple-darwin"),
        _ => None,
    }
}

/// The target of a machine whose `uname -sm` is `uname`.
fn uname_target(uname: &str) -> Option<&'static str> {
    let mut words = uname.split_whitespace();
    target_triple(words.next()?, words.next()?)
}

/// The target this binary runs on.
fn local_target() -> Option<&'static str> {
    target_triple(std::env::consts::OS, std::env::consts::ARCH)
}

/// The commit of a build id (`<hash>[+dirty.<fp>] <date>`, `hub::BUILD`):
/// two builds of one commit on different days, or with local edits, are the
/// same code to an update. `nogit` names no commit.
fn build_commit(build: &str) -> Option<&str> {
    let hash = build.split_whitespace().next()?.split('+').next()?;
    (hash.len() >= 7 && hash != "nogit").then_some(hash)
}

/// Whether the build `running` must not be replaced by `pushing` under
/// `--keep-newer`: it has local changes (`+dirty`, someone's own build), or
/// it was built on a later day than `pushing` (a host's self-update timer
/// moved it past the build being pushed). An own build is kept whatever is
/// pushed, also a binary that names no build (`pushing` is `None`); a build
/// with no date, or a pushed binary with none, is not newer.
fn keeps_over(running: &str, pushing: Option<&str>) -> Option<&'static str> {
    let head = running.split_whitespace().next()?;
    if head.contains("+dirty.") {
        return Some("ownBuild");
    }
    fn date(build: &str) -> Option<&str> {
        build.split_whitespace().nth(1).filter(|d| d.len() == 10)
    }
    match (date(running), pushing.and_then(date)) {
        (Some(running), Some(pushing)) if running > pushing => Some("newer"),
        _ => None,
    }
}

/// Whether two build ids name one commit (short hashes of two lengths too).
fn same_commit(a: &str, b: &str) -> bool {
    match (build_commit(a), build_commit(b)) {
        (Some(a), Some(b)) => a.starts_with(b) || b.starts_with(a),
        _ => false,
    }
}

/// The build id in `acpmux --version`'s `acpmux <version> (<build>)`.
fn version_build(version: &str) -> Option<&str> {
    let open = version.find('(')?;
    let close = version.rfind(')')?;
    version.get(open + 1..close)
}

/// The build id an acpmux binary carries, read from its bytes, so a binary
/// for another platform is not run: clap's version text
/// `<version> (<hash>[+dirty.<fp>] <date>)` is one string in it.
fn embedded_build(bytes: &[u8]) -> Option<String> {
    let mut from = 0;
    while let Some(i) = bytes[from..].windows(2).position(|w| w == b" (") {
        let at = from + i;
        from = at + 2;
        if at == 0 || !bytes[at - 1].is_ascii_digit() {
            continue;
        }
        let rest = &bytes[from..bytes.len().min(from + 80)];
        let Some(end) = rest.iter().position(|&b| b == b')') else { continue };
        let Ok(text) = std::str::from_utf8(&rest[..end]) else { continue };
        if is_build_id(text) {
            return Some(text.to_owned());
        }
    }
    None
}

/// `<7-40 hex>[+dirty.<8 hex>] <YYYY-MM-DD>`, as build.rs writes it.
fn is_build_id(text: &str) -> bool {
    let Some((head, date)) = text.split_once(' ') else { return false };
    let (hash, dirty) = head.split_once('+').map_or((head, None), |(h, d)| (h, Some(d)));
    let hex = |s: &str| s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
    let date_ok = date.len() == 10
        && date
            .bytes()
            .enumerate()
            .all(|(i, b)| if i == 4 || i == 7 { b == b'-' } else { b.is_ascii_digit() });
    (7..=40).contains(&hash.len())
        && hex(hash)
        && dirty.is_none_or(|d| d.strip_prefix("dirty.").is_some_and(|fp| fp.len() == 8 && hex(fp)))
        && date_ok
}

/// What `host update` did on one peer: its row's `outcome`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Outcome {
    /// The daemon restarted on the pushed binary and answers with its build.
    Updated,
    /// The daemon already runs the pushed binary's commit; nothing changed.
    Current,
    /// `--if-idle`, and a session runs a turn or waits on a permission (or
    /// its sessions could not be read); nothing changed.
    Busy,
    /// `--binary-dir` has no binary for the peer's target, or without it
    /// this binary is built for another one; nothing changed.
    NeedsBinary,
    /// The update failed after it changed the peer; the previous binary (and
    /// unit) run again.
    RolledBack,
    /// Refused before any change, or the rollback failed too.
    Failed,
    /// The peer is held (`host hold`, `host_hold.rs`): not reached at all.
    Held,
}

impl Outcome {
    fn as_str(self) -> &'static str {
        match self {
            Self::Updated => "updated",
            Self::Current => "current",
            Self::Busy => "busy",
            Self::NeedsBinary => "needsBinary",
            Self::RolledBack => "rolledBack",
            Self::Failed => "failed",
            Self::Held => "held",
        }
    }

    /// Whether the command fails (exit 1) for it.
    fn failed(self) -> bool {
        matches!(self, Self::RolledBack | Self::Failed)
    }
}

/// One peer's row in `host update`'s output (see [`update`]).
#[derive(Debug)]
struct PeerUpdate {
    outcome: Outcome,
    target: Option<&'static str>,
    /// The build the peer's daemon runs afterwards; None when none answers.
    build: Option<String>,
    /// The pushed binary's `--version`.
    version: Option<String>,
    /// The restarted daemon's `--json daemon status`, cut to 400 bytes.
    status: Option<String>,
    reason: Option<String>,
    error: Option<String>,
    migrated_from: Option<String>,
    /// Why the host is left without its self-update timer, when it is.
    auto_update_off: Option<String>,
    /// Why a macOS daemon was started in place, not as its launchd job
    /// ([`IN_PLACE`]): `noGuiLogin` or `bootstrapFailed`.
    in_place: Option<String>,
}

impl PeerUpdate {
    fn new() -> Self {
        PeerUpdate {
            outcome: Outcome::Failed,
            target: None,
            build: None,
            version: None,
            status: None,
            reason: None,
            error: None,
            migrated_from: None,
            auto_update_off: None,
            in_place: None,
        }
    }

    fn end(mut self, outcome: Outcome, reason: &str, error: impl Into<String>) -> Self {
        self.outcome = outcome;
        self.reason = Some(reason.to_owned());
        self.error = Some(error.into());
        self
    }

    fn to_json(&self, peer: &str, host: &str) -> Value {
        let mut v = json!({
            "peer": peer,
            "host": host,
            "outcome": self.outcome.as_str(),
            "ok": !self.outcome.failed(),
            "build": self.build,
        });
        let optional = [
            ("target", self.target.map(str::to_owned)),
            ("version", self.version.clone()),
            ("status", self.status.clone()),
            ("reason", self.reason.clone()),
            ("error", self.error.clone()),
            ("migratedFrom", self.migrated_from.clone()),
            ("autoUpdateOff", self.auto_update_off.clone()),
            ("inPlace", self.in_place.clone()),
        ];
        for (key, value) in optional {
            if let Some(value) = value {
                v[key] = json!(value);
            }
        }
        v
    }

    /// The human line after `NAME (HOST): `.
    fn line(&self) -> String {
        let error = self.error.as_deref().unwrap_or("");
        match self.outcome {
            Outcome::Updated => {
                let version = self.version.as_deref().unwrap_or("updated");
                let line = match &self.migrated_from {
                    Some(unit) => format!("{version} (moved from {unit} to acpmux.service)"),
                    None => version.to_owned(),
                };
                let line = match &self.in_place {
                    Some(why) => format!("{line} (started in place: {why})"),
                    None => line,
                };
                match &self.auto_update_off {
                    Some(why) => format!("{line}; auto-update off: {why}"),
                    None => line,
                }
            }
            Outcome::Current => format!("current ({})", self.build.as_deref().unwrap_or("?")),
            Outcome::Busy => format!("busy, left alone: {error}"),
            Outcome::NeedsBinary => format!("needs a binary: {error}"),
            Outcome::RolledBack => format!("rolled back: {error}"),
            Outcome::Failed => error.to_owned(),
            Outcome::Held => format!("held, left alone: {error}"),
        }
    }
}

/// `host update`'s choices for every peer.
pub(crate) struct UpdateOptions {
    /// Push `<dir>/acpmux-<target>` instead of this binary.
    pub binary_dir: Option<PathBuf>,
    /// Leave a peer whose sessions run a turn or wait on a permission alone.
    pub if_idle: bool,
    /// Leave a peer on a later day's build or on a build with local changes
    /// alone (`current`, reason `newer` or `ownBuild`), checked under the lock.
    pub keep_newer: bool,
    /// The session this command runs in, and its daemon.
    pub caller: Option<Caller>,
}

/// The session `host update` runs in: its `ACPMUX_SESSION_ID`, and the
/// `personInstance` of the daemon it belongs to (the one this CLI talks
/// to; random per daemon run). A session id is daemon-local, so only that
/// daemon's session of that id is the caller.
pub(crate) struct Caller {
    pub session: String,
    pub daemon: String,
}

/// [`update_peer`] holding the host's update lock ([`lock_updates`]), so
/// another update of the host (its self-update timer, or a `host update`,
/// `host setup` or `host enroll --fix` from another machine) does not change
/// the binary or `acpmux.prev` under it; `updateRunning` (nothing changed)
/// while one does.
fn update_locked(remote: &dyn Remote, opts: &UpdateOptions) -> PeerUpdate {
    match lock_updates(remote) {
        Ok(Some(lock)) => update_peer(&lock.fence(remote), opts),
        Ok(None) => {
            let why = format!(
                "another update of {} is running (its acpmux-update.timer, or a host update): run this again once it ended",
                remote.host()
            );
            PeerUpdate::new().end(Outcome::Failed, "updateRunning", why)
        }
        Err(e) => PeerUpdate::new().end(Outcome::Failed, "unreachable", e.to_string()),
    }
}

/// [`update_locked`], unless peer `name` is held ([`Holds::why`]): then
/// nothing reaches `remote`, not even ssh, and the row is `held`. The holds
/// are read right before the peer is, so one written meanwhile counts; a
/// holds file that cannot be read leaves the peer alone too (`failed`,
/// `holdsUnreadable`): a hold is never skipped on a guess.
fn update_unless_held(
    name: &str,
    remote: &dyn Remote,
    holds: &Path,
    now: u64,
    opts: &UpdateOptions,
) -> PeerUpdate {
    let holds = match Holds::read(holds) {
        Ok(holds) => holds,
        Err(e) => {
            return PeerUpdate::new().end(Outcome::Failed, "holdsUnreadable", format!("{e:#}"));
        }
    };
    match holds.why(name, remote.host(), now) {
        Some(why) => PeerUpdate::new().end(Outcome::Held, "held", why),
        None => update_locked(remote, opts),
    }
}

/// Update one peer: read it, push the binary, restart the daemon, check it
/// answers with the pushed build, and roll back when it does not. Nothing
/// changes on the peer before the push. Every script runs with the daemon's
/// environment ([`SERVICE_ENV`]). The caller holds the host's update lock
/// and passes `remote` fenced for it, so a step after the lease went fails.
fn update_peer(remote: &dyn Remote, opts: &UpdateOptions) -> PeerUpdate {
    let remote = &ServiceEnv(remote);
    let up = PeerUpdate::new();
    let caller = opts.caller.as_ref();
    let probe = match remote.exec(&probe_script(opts.if_idle), None) {
        Ok(out) => match Probe::parse(&out, caller) {
            Some(probe) => probe,
            None => {
                let why = out.stderr.trim();
                return up.end(
                    Outcome::Failed,
                    "unreachable",
                    format!("ssh {} failed: {why}", remote.host()),
                );
            }
        },
        Err(e) => return up.end(Outcome::Failed, lock_lost_or(&e, "unreachable"), e.to_string()),
    };
    let mut up =
        PeerUpdate { target: uname_target(&probe.uname), build: probe.build.clone(), ..up };
    if probe.cloud_vm {
        let why = format!(
            "{} is a cmux Cloud VM: update it with `cmux link machine update --to-bundled`",
            remote.host()
        );
        return up.end(Outcome::Failed, "cloudMachine", why);
    }
    let Some(target) = up.target else {
        let why = format!("no acpmux build runs on {} ({})", remote.host(), probe.uname);
        return up.end(Outcome::Failed, "unsupportedPlatform", why);
    };
    let (binary, binary_build) = match &opts.binary_dir {
        Some(dir) => {
            let path = dir.join(format!("acpmux-{target}"));
            if !path.is_file() {
                let why = format!("{} has no acpmux-{target}", dir.display());
                return up.end(Outcome::NeedsBinary, "noBinary", why);
            }
            let build = std::fs::read(&path).ok().and_then(|bytes| embedded_build(&bytes));
            (path, build)
        }
        // Never a macOS binary to Linux, or one architecture to another.
        None if local_target() != Some(target) => {
            let why = format!(
                "this acpmux is {}, {} is {target}: pass --binary-dir with a build for it",
                local_target().unwrap_or("another platform"),
                remote.host()
            );
            return up.end(Outcome::NeedsBinary, "wrongPlatform", why);
        }
        None => match crate::self_command::SelfCommand::current() {
            Ok(own) => (own.exe, Some(crate::hub::BUILD.to_owned())),
            Err(e) => return up.end(Outcome::Failed, "noBinary", e.to_string()),
        },
    };
    if let (Some(running), Some(pushing)) = (&probe.build, &binary_build)
        && same_commit(running, pushing)
    {
        // A daemon under a hand-written unit stays there until a build to
        // push comes: moving it would start acpmux.service on whatever
        // binary its path holds.
        up.outcome = Outcome::Current;
        return up;
    }
    // Read under the host's update lock, so a self-update that ran since the
    // caller looked is seen here and never undone.
    if opts.keep_newer
        && let Some(running) = &probe.build
        && let Some(reason) = keeps_over(running, binary_build.as_deref())
    {
        let pushing = binary_build.as_deref().unwrap_or("a binary with no build id");
        let why = format!("{} runs {running}, kept over {pushing}", remote.host());
        return up.end(Outcome::Current, reason, why);
    }
    if opts.if_idle {
        match &probe.busy {
            Some(names) if names.is_empty() => {}
            Some(names) => {
                let why = format!("mid-turn or waiting on a permission: {}", names.join(", "));
                return up.end(Outcome::Busy, "busy", why);
            }
            None => {
                let why = "its sessions could not be read, so one may be mid-turn";
                return up.end(Outcome::Busy, "unknown", why);
            }
        }
    }
    if let Some((reason, why)) = &probe.refused {
        return up.end(Outcome::Failed, reason, why.clone());
    }
    // From here on the peer changes.
    let running = probe.build.as_deref().and_then(build_commit);
    let version = match push_update(remote, &binary, running) {
        Ok(version) => version,
        // The install checks the pushed binary runs before it replaces
        // anything, so the installed one is still the old one.
        Err(e) => return up.end(Outcome::Failed, lock_lost_or(&e, "pushFailed"), e.to_string()),
    };
    let pushed = version_build(&version).map(str::to_owned);
    up.version = Some(version);
    if let (Some(pushed), Some(expected)) = (&pushed, &binary_build)
        && !same_commit(pushed, expected)
    {
        let mut why = format!("the pushed binary reports build {pushed}, not {expected}");
        if let Err(e) = run(remote, RESTORE_PREV) {
            why.push_str(&format!("; putting the previous one back failed: {e}"));
        }
        return up.end(Outcome::Failed, "pushMismatch", why);
    }
    // A turn may have started while the binary was copied: read the
    // sessions again right before the restart, and put the binary back
    // rather than restart under it.
    if opts.if_idle {
        let again = match remote.exec(&probe_script(true), None) {
            Ok(out) => Some(out),
            Err(e) if e.is::<LockLost>() => {
                return up.end(Outcome::Failed, "lockLost", e.to_string());
            }
            Err(_) => None,
        };
        let busy = match again.as_ref().and_then(|out| Probe::parse(out, caller)) {
            Some(Probe { busy: Some(names), .. }) if names.is_empty() => None,
            Some(Probe { busy: Some(names), .. }) => {
                Some(("busy", format!("mid-turn or waiting on a permission: {}", names.join(", "))))
            }
            _ => Some(("unknown", "its sessions could not be read, so one may be mid-turn".into())),
        };
        if let Some((reason, mut why)) = busy {
            up.version = None;
            if let Err(e) = run(remote, RESTORE_PREV) {
                why.push_str(&format!("; putting the previous binary back failed: {e}"));
                return up.end(Outcome::Failed, reason, why);
            }
            return up.end(Outcome::Busy, reason, why);
        }
    }
    let linux = probe.uname.starts_with("Linux");
    let restart = if linux { linux_restart(false, true) } else { launchd_restart() };
    let restarted = restart_checked(remote, &restart, pushed.as_deref());
    let (reason, why) = match restarted.result {
        Ok(status) => {
            up.auto_update_off = restarted.auto_update_off;
            up.in_place = restarted.in_place;
            up.build = answering_build(&status);
            up.status = Some(cut(status, 400));
            up.migrated_from = restarted.migrating;
            up.outcome = Outcome::Updated;
            return up;
        }
        Err(failure) => failure,
    };
    // The lease went: nothing more runs there, a rollback neither.
    if reason == "lockLost" {
        return up.end(Outcome::Failed, &reason, why);
    }
    // Refused before the daemon was touched: only the binary goes back.
    if restarted.refused {
        let mut why = why;
        if let Err(e) = run(remote, RESTORE_PREV) {
            why.push_str(&format!("; putting the previous binary back failed: {e}"));
        }
        return up.end(Outcome::Failed, &reason, why);
    }
    let rollback = match &restarted.migrating {
        Some(unit) => match migrate_back(unit) {
            Some(script) => script,
            None => {
                let why = format!("{why}; cannot move it back to {unit}");
                return up.end(Outcome::Failed, &reason, why);
            }
        },
        None => {
            let restart = if linux {
                format!("systemctl --user reset-failed acpmux.service >/dev/null 2>&1; {restart}")
            } else {
                restart
            };
            format!(
                "{RESTORE_PREV} || {{ echo 'no previous binary to put back' >&2; exit 1; }}\n{restart}"
            )
        }
    };
    let back = restart_checked(remote, &rollback, None);
    match back.result {
        Ok(status) => {
            up.build = answering_build(&status);
            up.in_place = back.in_place;
            up.end(Outcome::RolledBack, &reason, why)
        }
        // Refused before it stopped anything: whatever runs keeps running.
        Err((_, again)) if back.refused => {
            let status = remote.exec(AWAIT_DAEMON, None).map(|o| o.stdout).unwrap_or_default();
            up.build = answering_build(&status);
            let why = format!("{why}; the rollback stopped nothing ({again})");
            up.end(Outcome::Failed, &reason, why)
        }
        Err((_, again)) => {
            up.build = None;
            up.end(Outcome::Failed, &reason, format!("{why}; the rollback failed too: {again}"))
        }
    }
}

/// `lockLost` for an update whose lease went ([`LockLost`]), else `reason`.
fn lock_lost_or<'a>(e: &anyhow::Error, reason: &'a str) -> &'a str {
    if e.is::<LockLost>() { "lockLost" } else { reason }
}

/// A restart script's run, then the daemon's answer.
struct Restarted {
    /// The hand-written unit a migration started moving the daemon from.
    migrating: Option<String>,
    /// The script refused before it changed anything ([`REFUSED`]).
    refused: bool,
    /// The daemon's status, or why it failed: a reason code and a message.
    result: std::result::Result<String, (String, String)>,
    /// Why the script left the host without its self-update timer.
    auto_update_off: Option<String>,
    /// Why the script started the daemon in place ([`IN_PLACE`]).
    in_place: Option<String>,
}

/// Run a restart script, then wait for the daemon to answer
/// ([`AWAIT_DAEMON`]); with `want`, with that build's commit.
fn restart_checked(remote: &dyn Remote, script: &str, want: Option<&str>) -> Restarted {
    let failed = |migrating: Option<String>, refused: bool, reason: &str, why: String| Restarted {
        migrating,
        refused,
        result: Err((reason.to_owned(), why)),
        auto_update_off: None,
        in_place: None,
    };
    let out = match remote.exec(script, None) {
        Ok(out) => out,
        Err(e) => return failed(None, false, lock_lost_or(&e, "restartFailed"), e.to_string()),
    };
    let migrating = out.stdout.lines().find_map(|l| l.strip_prefix(MIGRATING)).map(str::to_owned);
    if !out.ok {
        let why = match out.stderr.lines().rev().find(|l| !l.trim().is_empty()) {
            Some(line) => line.trim().to_owned(),
            None => "the restart failed and said nothing".to_owned(),
        };
        if let Some(code) = out.stdout.lines().find_map(|l| l.strip_prefix(REFUSED)) {
            return failed(migrating, true, code, why);
        }
        return failed(migrating, false, "restartFailed", why);
    }
    let status = match remote.exec(AWAIT_DAEMON, None) {
        Ok(out) => out.stdout.trim().to_owned(),
        Err(e) => return failed(migrating, false, lock_lost_or(&e, "noAnswer"), e.to_string()),
    };
    let Some(build) = answering_build(&status) else {
        let why = "the daemon did not answer within 20 s of its restart".to_owned();
        return failed(migrating, false, "noAnswer", why);
    };
    if let Some(want) = want
        && !same_commit(&build, want)
    {
        let why = format!("the restarted daemon runs build {build}, not the pushed {want}");
        return failed(migrating, false, "buildMismatch", why);
    }
    let auto_update_off = take_auto_update_off(&out.stdout).1;
    let in_place = out.stdout.lines().find_map(|l| l.strip_prefix(IN_PLACE)).map(str::to_owned);
    Restarted { migrating, refused: false, result: Ok(status), auto_update_off, in_place }
}

/// `text` cut to at most `max` bytes, on a character boundary.
fn cut(mut text: String, max: usize) -> String {
    if text.len() > max {
        let mut end = max;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    text
}

/// Update one ssh peer, or every one, to this binary (or the one for its
/// target in `--binary-dir`) and restart it; see [`update_peer`].
///
/// `--json` prints `{"updated": [ROW...], "peers": [...]}` (the peers as
/// `host ls --json` lists them), one ROW per peer:
///
/// ```json
/// {"peer": "huge-blue", "host": "huge-blue", "outcome": "updated", "ok": true,
///  "build": "d5829ffea 2026-10-21", "target": "x86_64-unknown-linux-musl",
///  "version": "acpmux 1.0.0 (d5829ffea 2026-10-21)", "status": "{...}",
///  "migratedFrom": "acpmux-agent-huge-blue.service"}
/// ```
///
/// - `outcome`: `updated`, `current` (already that commit), `busy`
///   (`--if-idle`), `held` (`host hold`: not reached at all),
///   `needsBinary` (`--binary-dir` lacks `acpmux-<target>`, or without it
///   this binary is for another target),
///   `rolledBack` (the restarted daemon failed its check; the previous
///   binary and unit run again) or `failed`. Only `updated` and `rolledBack`
///   restarted the daemon (a `busy` after the push only refreshed
///   `acpmux.prev`); `ok` is false for `rolledBack` and `failed`.
/// - `build`: the build the peer's daemon runs afterwards, null when none
///   answers. `target`: the peer's release target, once known.
/// - `version` and `status`: the pushed binary's `--version` and the
///   restarted daemon's status text (cut to 400 bytes), after a push.
/// - `reason` and `error`, on every outcome but `updated` and `current`: a
///   code (`busy`, `unknown`, `held`, `holdsUnreadable` (`host hold`'s
///   file could not be read, so the peer was not reached), `noBinary`,
///   `wrongPlatform`, `unsupportedPlatform`, `cloudMachine`, `unreachable`, `updateRunning`
///   (another update of the host, such as its self-update timer, holds its
///   update lock), `lockLost` (this update's hold on that lock ended, its
///   connection dropped: it changed nothing more), `pushFailed`, `pushMismatch`,
///   `restartFailed`, `noAnswer`, `buildMismatch`, and for a daemon under a
///   hand-written unit `unitConflict`, `listenConflict`, `unitArgs`,
///   `unitSettings`, `unitElsewhere`, `noLinger`; on macOS `launchdRefused`:
///   launchd starts no job now, so the daemon was left running) and a message.
/// - `migratedFrom`: the hand-written unit the daemon was moved from to
///   `acpmux.service`.
/// - `inPlace`: a macOS daemon started in place, not as its launchd job:
///   `noGuiLogin` (no one is logged in at the screen) or `bootstrapFailed`.
///
/// Exits 1 when any peer is `rolledBack` or `failed`.
pub(crate) async fn update(
    client: Arc<Client>,
    name: Option<String>,
    all: bool,
    opts: UpdateOptions,
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
    let holds = holds_path();
    let mut rows = Vec::new();
    for (n, host) in targets {
        let up = update_unless_held(&n, &SshRemote(&host), &holds, now_ms(), &opts);
        if !json_out {
            if up.outcome.failed() {
                eprintln!("{n} ({host}): {}", up.line());
            } else {
                println!("{n} ({host}): {}", up.line());
            }
        }
        rows.push((n, host, up));
    }
    let mut peers = json!({});
    // A restarted daemon (updated, or back on its previous build) is reconnected now.
    for (name, _, _) in
        rows.iter().filter(|r| matches!(r.2.outcome, Outcome::Updated | Outcome::RolledBack))
    {
        peers = connect_peer(&client, name, None).await?;
    }
    if peers.get("peers").is_none() {
        peers = client.request("_acpmux/peers", json!({})).await?;
    }
    if json_out {
        let updated: Vec<Value> = rows.iter().map(|(n, h, up)| up.to_json(n, h)).collect();
        print_json(&json!({"updated": updated, "peers": peers.get("peers")}));
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
    if rows.iter().any(|r| r.2.outcome.failed()) {
        std::process::exit(1);
    }
    Ok(())
}

#[cfg(test)]
#[path = "host_update_tests.rs"]
mod tests;
