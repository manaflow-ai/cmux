//! `acpmux host enroll` and `host doctor`: the Add Machine checklist
//! (plans/cmux-next/add-machine-DESIGN.md). Each step checks the machine
//! and, with `fix` (always on for enroll), repairs what its check found; a
//! step whose dependency did not pass is `skip`. One JSON line per step as
//! it finishes, then `{"report":{...}}`. Without `fix` nothing changes.

use crate::cli::errors::{AppError, Code};
use crate::cli::host_peering::{self, PeerTarget};
use crate::cli::host_steps::{REASON_NOT_THIS_PROGRAM, Report, Step, StepResult, StepState};
use crate::cli::hosts::{self, DAEMON_BIN, Remote, SshRemote};
use crate::client::Client;
use crate::harness_health::channel::quote as shell_quote;
use anyhow::Result;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[path = "host_enroll_daemon.rs"]
mod daemon_step;
use daemon_step::daemon;
#[cfg(test)]
use daemon_step::{Verdict, judge_daemon};

/// The machine enroll or doctor works on.
pub(crate) struct Plan {
    pub name: String,
    pub host: String,
    /// The remote daemon's WebSocket port (the peer url's): a known peer's,
    /// else None, the port the host's daemon already listens on (default
    /// [`crate::peer::SSH_PEER_PORT`] when it has no listener yet).
    pub port: Option<u16>,
    pub harnesses: Vec<String>,
    /// The remote binary `install` checks and pushes; when it is not
    /// [`DAEMON_BIN`], that path becomes a link to it.
    pub remote_binary: String,
    /// Run `peer-back` (`--reverse`); off by default, it is reported `skip`.
    pub reverse: bool,
}

impl Plan {
    /// `host enroll HOST`: named after the host's first label unless `name`.
    pub(crate) fn enroll(
        host: String,
        name: Option<String>,
        harnesses: Vec<String>,
        remote_binary: String,
        reverse: bool,
    ) -> Self {
        Self {
            name: name.unwrap_or_else(|| hosts::short_name(&host)),
            host,
            port: None,
            harnesses,
            remote_binary,
            reverse,
        }
    }
}

/// This machine's side of the harness step.
pub(crate) struct Local {
    pub harness_dir: Option<PathBuf>,
    pub home: Option<PathBuf>,
}

/// What a person does when this build cannot run on the host.
const INSTALL_FROM_APP: &str = "Install cmux on {host} from the app (Machines > Add Machine installs the right build) or `cmux remote install`";

/// The remote user harness folder (what `ProfileSources::current` reads on
/// a standalone acpmux or a shipped cmux), as a shell assignment.
const REMOTE_HARNESS_DIR: &str = "d=${XDG_CONFIG_HOME:-$HOME/.config}/cmux/harnesses";

/// Set by a caller that stops a run by its process group (the app's Add
/// Machine card, `HostCLI.stop`).
const PROCESS_GROUP_ENV: &str = "ACPMUX_PROCESS_GROUP";

/// With [`PROCESS_GROUP_ENV`] set, lead a new process group, so stopping
/// the run also stops the ssh and scp it started. Never in a terminal's
/// job, whose Ctrl-C must still reach it.
pub(crate) fn lead_process_group_if_asked() {
    #[cfg(unix)]
    if std::env::var_os(PROCESS_GROUP_ENV).is_some_and(|v| v == "1") {
        // SAFETY: setpgid on this process alone, before it starts a child.
        unsafe {
            libc::setpgid(0, 0);
        }
    }
}

pub(crate) async fn run(client: Arc<Client>, plan: Plan, fix: bool, json_out: bool) -> Result<()> {
    lead_process_group_if_asked();
    let local = Local {
        harness_dir: crate::config::profiles::ProfileSources::current().user_dir,
        home: dirs::home_dir(),
    };
    let mut emit = |r: &StepResult| print_step(r, json_out);
    let remote = SshRemote(&plan.host);
    let (mut done, port) = machine_steps(&remote, &plan, &local, fix, &mut emit);
    let local_name = hosts::short_name(&crate::hand::pair::hostname());
    let t = PeerTarget {
        name: &plan.name,
        host: &plan.host,
        port,
        local_name: &local_name,
        local_dest: None,
    };
    for step in [Step::Peer, Step::PeerBack, Step::Identity, Step::Approvals] {
        let result = match gate(step, &done) {
            Some(skip) => skip,
            None => match step {
                Step::Peer => host_peering::peer(&client, &t, fix).await,
                Step::PeerBack if !plan.reverse => peer_back_off(),
                Step::PeerBack => host_peering::peer_back(&t, fix).await,
                Step::Approvals => {
                    let io = host_peering::Live(Some(&*client));
                    crate::cli::host_approvals::approvals_with(&io, &t, fix).await
                }
                _ => host_peering::identity(&client, &t, fix).await,
            },
        };
        emit(&result);
        done.push(result);
    }
    let report = Report::new(&plan.name, &plan.host, done);
    if json_out {
        println!("{}", report_line(&report));
    } else {
        let verdict = if report.ok { "healthy" } else { "needs attention" };
        println!("{} ({}): {verdict}", report.name, report.host);
    }
    if !report.ok {
        // After the report: exit 1, with the error envelope on stderr.
        let why = format!("{} ({}) needs attention", report.name, report.host);
        let mut error = AppError::new(Code::Runtime, "unhealthy", why);
        if let Some(step) = report.steps.iter().find(|step| step.state == StepState::Fail) {
            let mut data = step.data.clone().unwrap_or_else(|| json!({}));
            if let Some(reason) = step.reason {
                data["reason"] = json!(reason);
            }
            error = error.with_data(data);
        }
        return Err(error.into());
    }
    Ok(())
}

/// `peer-back` without `--reverse`: two daemons that list each other relay
/// one another's sessions both ways, so this machine is only added on the
/// host when asked.
pub(crate) fn peer_back_off() -> StepResult {
    StepResult::new(
        Step::PeerBack,
        StepState::Skip,
        "not asked to add this machine on the host (pass --reverse)",
    )
}

/// The name, host and port `doctor NAME|HOST` works on: a peer with that
/// name, else the peer at that ssh host, else the host itself (its port:
/// the one its daemon listens on).
pub(crate) fn pick_target(peers: &[Value], target: &str) -> (String, String, Option<u16>) {
    let ssh_peers = peers.iter().filter_map(|p| {
        let name = p.get("name").and_then(Value::as_str)?;
        let t = crate::peer::ssh_target(p.get("url").and_then(Value::as_str)?).ok()?;
        Some((name.to_owned(), t.destination, Some(t.port)))
    });
    let ssh_peers: Vec<_> = ssh_peers.collect();
    ssh_peers
        .iter()
        .find(|(name, _, _)| name == target)
        .or_else(|| ssh_peers.iter().find(|(_, host, _)| host == target))
        .cloned()
        .unwrap_or_else(|| (hosts::short_name(target), target.to_owned(), None))
}

/// reach, install, daemon and harness: the steps on the machine itself,
/// and the port the peer link uses (the daemon step's).
fn machine_steps(
    r: &dyn Remote,
    plan: &Plan,
    local: &Local,
    fix: bool,
    emit: &mut dyn FnMut(&StepResult),
) -> (Vec<StepResult>, u16) {
    let mut done = Vec::new();
    let mut port = plan.port.unwrap_or(crate::peer::SSH_PEER_PORT);
    for step in [Step::Reach, Step::Install, Step::Daemon, Step::Harness] {
        let result = gate(step, &done).unwrap_or_else(|| match step {
            Step::Reach => reach(r),
            Step::Install => install(r, &plan.name, &plan.remote_binary, fix),
            Step::Daemon => {
                let (result, listening) = daemon(r, &plan.name, plan.port, fix);
                port = listening;
                result
            }
            _ => harness(r, &plan.name, &plan.harnesses, local, fix),
        });
        emit(&result);
        done.push(result);
    }
    (done, port)
}

/// The steps that must have passed before this one runs. A skipped step
/// blocks too, so a failure skips everything downstream of it.
fn needs(step: Step) -> &'static [Step] {
    match step {
        Step::Reach => &[],
        Step::Install | Step::Identity => &[Step::Reach],
        Step::Daemon => &[Step::Install],
        Step::Harness | Step::Peer | Step::PeerBack | Step::Approvals => &[Step::Daemon],
    }
}

fn gate(step: Step, done: &[StepResult]) -> Option<StepResult> {
    let passed =
        |s: &StepResult| matches!(s.state, StepState::Ok | StepState::Fixed | StepState::Warn);
    let blocker =
        needs(step).iter().find(|need| done.iter().any(|d| d.step == **need && !passed(d)))?;
    Some(StepResult::new(step, StepState::Skip, format!("needs {}", word(blocker))))
}

/// A step or state as its JSON word.
fn word(v: &impl serde::Serialize) -> String {
    serde_json::to_value(v).ok().and_then(|v| v.as_str().map(str::to_owned)).unwrap_or_default()
}

pub(crate) fn step_line(r: &StepResult) -> String {
    serde_json::to_string(r).unwrap_or_default()
}

pub(crate) fn report_line(report: &Report) -> String {
    serde_json::to_string(&json!({"report": report})).unwrap_or_default()
}

fn print_step(r: &StepResult, json_out: bool) {
    if json_out {
        println!("{}", step_line(r));
        return;
    }
    println!("{:<6} {:<9} {}", word(&r.state), word(&r.step), r.detail);
    if let Some(fix) = &r.fix {
        println!("{:<16} {fix}", "");
    }
}

fn fail(step: Step, detail: impl Into<String>, fix: impl Into<String>) -> StepResult {
    let detail = detail.into();
    let fix = fix.into();
    let reason = match step {
        Step::Reach => "ssh_unreachable",
        Step::Install => "remote_install_failed",
        Step::Daemon => "remote_daemon_unhealthy",
        Step::Harness => "remote_harness_unhealthy",
        Step::Peer => "peer_unreachable",
        Step::PeerBack => "peer_back_unreachable",
        Step::Identity => "peer_identity_failed",
        Step::Approvals => "approvals_unavailable",
    };
    let mut result = StepResult::new(step, StepState::Fail, detail).with_fix(fix);
    // A missing standalone link is an intentional handoff to the app's own
    // installer; retain the legacy shape so callers do not treat it as a
    // repairable remote failure.
    if !(step == Step::Install && result.detail.ends_with(" is missing")) {
        result = result.with_reason(reason);
        if let Some(command) = result.fix.clone().as_deref().and_then(|fix| fix.split('`').nth(1)) {
            result = result.with_try(command.to_owned());
        }
    }
    result
}

/// Why `ssh -o BatchMode=yes HOST true` failed, from its stderr.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SshFailure {
    NoRoute,
    SshOff,
    KeyRejected,
    HostKeyChanged,
    Other,
}

impl SshFailure {
    fn of(stderr: &str) -> Self {
        let s = stderr.to_ascii_lowercase();
        let any = |needles: &[&str]| needles.iter().any(|n| s.contains(n));
        // ssh prints the host key warning before anything else it reports.
        if any(&["remote host identification has changed", "host key verification failed"]) {
            Self::HostKeyChanged
        } else if any(&["connection refused"]) {
            Self::SshOff
        } else if any(&["permission denied", "too many authentication failures"]) {
            Self::KeyRejected
        } else if any(&[
            "could not resolve hostname",
            "name or service not known",
            "nodename nor servname",
            "temporary failure in name resolution",
            "no route to host",
            "network is unreachable",
            "host is down",
            "timed out",
        ]) {
            Self::NoRoute
        } else {
            Self::Other
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::NoRoute => "no route to the host",
            Self::SshOff => "ssh is off (connection refused)",
            Self::KeyRejected => "the ssh key was rejected",
            Self::HostKeyChanged => "the host key does not match or is not known yet",
            Self::Other => "ssh failed",
        }
    }

    fn fix(self, host: &str) -> String {
        let bare = host.rsplit('@').next().unwrap_or(host);
        match self {
            Self::NoRoute => tailnet_acl_hint(host).unwrap_or_else(|| {
                format!(
                    "Check the name {bare}, that the machine is on, and that it is on this network or tailnet."
                )
            }),
            Self::SshOff => format!(
                "Turn on ssh on {bare} (macOS: System Settings > General > Sharing > Remote Login; Linux: start sshd)."
            ),
            Self::KeyRejected => format!(
                "Add this machine's public key to ~/.ssh/authorized_keys on {bare} (for example `ssh-copy-id {host}`), then check again."
            ),
            Self::HostKeyChanged => format!(
                "If {bare} was reinstalled, remove its old key with `ssh-keygen -R {bare}`; then (or if it is new to this machine) run `ssh {host}` once and accept its key."
            ),
            Self::Other => format!("Run `ssh {host}` in a terminal to see why it fails."),
        }
    }
}

/// A MagicDNS timeout is often a tailnet policy denial rather than an offline host. Keep the
/// diagnosis conditional because a plain SSH destination has no evidence that Tailscale is in use.
fn tailnet_acl_hint(host: &str) -> Option<String> {
    let bare = host.rsplit('@').next().unwrap_or(host).trim_matches(['[', ']']);
    bare.strip_suffix(".ts.net")?;
    Some(format!(
        "If `tailscale ping {bare}` works but ssh times out, Tailscale SSH isn't allowed to this machine: add an ACL rule like {{ \"src\": [\"autogroup:member\"], \"dst\": [\"{bare}\"], \"ip\": [\"tcp:22\"] }} or enable Tailscale SSH on the target, then check again."
    ))
}

fn reach(r: &dyn Remote) -> StepResult {
    let host = r.host();
    match r.exec("true", None) {
        Ok(out) if out.ok => {
            StepResult::new(Step::Reach, StepState::Ok, format!("ssh {host} works"))
        }
        Ok(out) => {
            let class = SshFailure::of(&out.stderr);
            let last = out.stderr.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("");
            fail(Step::Reach, format!("{}: {}", class.label(), last.trim()), class.fix(host))
        }
        Err(e) => fail(
            Step::Reach,
            format!("{e:#}"),
            "Give a plain ssh host (a name or user@name, without a port), and make sure ssh is installed.",
        ),
    }
}

/// The build in a `--version` line: `acpmux 0.1.0 (BUILD)`.
fn build_of(line: &str) -> Option<&str> {
    let (_, rest) = line.split_once('(')?;
    rest.trim_end().strip_suffix(')').map(str::trim).filter(|b| !b.is_empty())
}

/// Lists each acpmux the host has, in the order it would use them (its
/// PATH, the standalone install, the cmux apps, then a cmux-tui: the app's
/// SSH install at ~/.local/bin, `cmux remote install`'s ~/.cmux/bin, PATH),
/// with its version line, the file it resolves to (`readlink -f`, so a
/// link such as `~/.local/bin/acpmux` compares with the daemon's own resolved
/// `exe`), and what `daemon status` (which never starts a
/// daemon) says through it (a cmux-tui as `cmux-tui acp …`); then a NUL and
/// the daemon config. An app name may hold spaces: the glob's words stay
/// whole and a pattern that matched nothing fails `-f`.
const PROBE_BINS: &str = r#"seen=; for b in "$(command -v acpmux 2>/dev/null)" ~/.local/bin/acpmux /Applications/cmux*.app/Contents/Resources/bin/acpmux ~/.local/bin/cmux-tui ~/.cmux/bin/cmux-tui "$(command -v cmux-tui 2>/dev/null)"; do [ -n "$b" ] && [ -f "$b" ] && [ -x "$b" ] || continue; case "$seen" in *"|$b|"*) continue ;; esac; seen="$seen|$b|"; case "$b" in */acpmux) set -- "$b" ;; *) set -- "$b" acp ;; esac; printf 'bin\t%s\t%s\n' "$b" "$("$@" --version 2>/dev/null | head -n 1)"; printf 'real\t%s\t%s\n' "$b" "$(readlink -f "$b" 2>/dev/null)"; printf 'status\t%s\t%s\n' "$b" "$("$@" --json daemon status 2>/dev/null | tr -d '\n')"; done; printf '\0'; "#;

/// [`PROBE_BINS`], then the remote daemon config.
fn probe_script() -> String {
    format!(
        "printf 'uname\\t%s\\n' \"$(uname -sm)\"; {PROBE_BINS}cat {}/config.json 2>/dev/null",
        hosts::REMOTE_HOME
    )
}

/// What [`probe_script`] found.
#[derive(Debug, Default, PartialEq, Eq)]
struct Probe {
    /// The remote kernel and machine from `uname -sm`.
    uname: String,
    /// Each acpmux on the host and its build, in [`probe_script`] order.
    bins: Vec<(String, Option<String>)>,
    /// Each binary's resolved file (`readlink -f`), by its probed path, when
    /// the host could resolve it.
    real: std::collections::BTreeMap<String, String>,
    /// The first daemon that answered.
    running: Option<Running>,
    /// The running daemon's executable, when its `daemon status` names it
    /// (`exe`).
    exe: Option<String>,
    /// The running daemon runs as `cmux-tui acp …` from another file than
    /// [`DAEMON_BIN`] resolves to: a cmux session daemon started it
    /// (`cmux-tui/src/acp.rs`), outside launchd. One started through the
    /// `~/.local/bin/acpmux` link to that cmux-tui (`host setup`, enroll's
    /// daemon step) is not: its exe is the link's target.
    run_by_cmux_tui: bool,
    config: String,
}

#[derive(Debug, PartialEq, Eq)]
struct Running {
    /// The binary whose `daemon status` it answered.
    via: String,
    pid: u64,
    build: Option<String>,
    /// It holds a person key: the cmux app started it (`hub/person.rs`).
    person_key: bool,
    /// It runs as `cmux-tui acp …`, as its `daemon status` says
    /// (`runsAsCmuxTuiAcp`); None from a daemon too old to say who it is.
    cmux_tui_acp: Option<bool>,
    /// The address its WebSocket listener is bound to (`listen`), when it
    /// has one.
    listen: Option<String>,
}

/// The acpmux the host uses: the running daemon's, else the first binary.
#[derive(Debug, PartialEq, Eq)]
struct InUse {
    path: String,
    build: Option<String>,
    /// cmux's own: the app owns it and its daemon (an app bundle, a cmux
    /// session daemon, or a daemon too old to say who it is beside a cmux).
    app: bool,
    /// An app bundle runs it (an `.app` executable): only the app on the
    /// host changes its build. A person key alone does not say so.
    bundle: bool,
    pid: Option<u64>,
}

fn parse_probe(stdout: &str) -> Probe {
    let (list, config) = stdout.split_once('\0').unwrap_or((stdout, ""));
    let mut probe = Probe { config: config.to_owned(), ..Probe::default() };
    for line in list.lines() {
        if let Some(uname) = line.strip_prefix("uname\t") {
            probe.uname = uname.trim().to_owned();
            continue;
        }
        let mut parts = line.splitn(3, '\t');
        let (Some(kind), Some(path), rest) = (parts.next(), parts.next(), parts.next()) else {
            continue;
        };
        let rest = rest.unwrap_or("");
        match kind {
            "bin" => probe.bins.push((path.to_owned(), build_of(rest).map(str::to_owned))),
            "real" if rest.trim().starts_with('/') => {
                probe.real.insert(path.to_owned(), rest.trim().to_owned());
            }
            "status" if probe.running.is_none() => {
                let v: Value = serde_json::from_str(rest.trim()).unwrap_or(Value::Null);
                if let Some(pid) = v.get("pid").and_then(Value::as_u64) {
                    probe.running = Some(Running {
                        via: path.to_owned(),
                        pid,
                        build: v.get("build").and_then(Value::as_str).map(str::to_owned),
                        person_key: v.get("personKey").and_then(Value::as_bool) == Some(true),
                        cmux_tui_acp: v.get("runsAsCmuxTuiAcp").and_then(Value::as_bool),
                        listen: v.get("listen").and_then(Value::as_str).map(str::to_owned),
                    });
                    // The daemon names its own executable; an older one does not.
                    probe.exe = v
                        .get("exe")
                        .and_then(Value::as_str)
                        .filter(|e| e.starts_with('/'))
                        .map(str::to_owned);
                }
            }
            _ => {}
        }
    }
    probe
}

/// A path inside a macOS app bundle.
fn app_owned(path: &str) -> bool {
    path.contains(".app/Contents/")
}

/// A path whose file is named `cmux-tui`.
fn is_cmux_tui(path: &str) -> bool {
    path.rsplit('/').next() == Some("cmux-tui")
}

/// Whether the running daemon is a cmux session daemon's `cmux-tui acp`:
/// its status says it runs as one (`acp`), and its executable `exe` is not
/// the file [`DAEMON_BIN`] resolves to (`daemon_bin`, `readlink -f`), which
/// the standalone daemon runs. Linux names a replaced image `PATH (deleted)`.
fn cmux_session_daemon(acp: bool, exe: Option<&str>, daemon_bin: &str) -> bool {
    let exe = exe.map(|e| e.strip_suffix(" (deleted)").unwrap_or(e));
    acp && (daemon_bin.is_empty() || exe != Some(daemon_bin))
}

impl Probe {
    /// The file `path` resolves to on the host, else `path` itself.
    fn resolved<'a>(&'a self, path: &'a str) -> &'a str {
        self.real.get(path).map(String::as_str).unwrap_or(path)
    }

    fn in_use(&self) -> Option<InUse> {
        if let Some(run) = &self.running {
            let app_bin = self.bins.iter().any(|(path, _)| app_owned(path));
            // The app's own bundle runs it: its executable (else, when it
            // names none, a binary) is in an app. Never from the person key:
            // the app hands one to an SSH host's cmux-tui daemon too.
            let bundle = match &self.exe {
                Some(exe) => app_owned(exe),
                None => app_bin && !is_cmux_tui(&run.via),
            };
            // When the host does not name the daemon's executable, a daemon
            // on a host with a cmux app counts as the app's: never restart
            // what may be the app's daemon. One a cmux session daemon started
            // as `cmux-tui acp` is cmux's too: launchd must not start a
            // second one beside it. A daemon too old to say who it is counts
            // as cmux's whenever a cmux-tui or a cmux app is there: it warns,
            // and nothing is installed or restarted beside it.
            let app = run.person_key
                || bundle
                || self.run_by_cmux_tui
                || (run.cmux_tui_acp.is_none()
                    && (app_bin
                        || is_cmux_tui(&run.via)
                        || self.bins.iter().any(|(path, _)| is_cmux_tui(path))));
            let path = self.exe.clone().unwrap_or_else(|| run.via.clone());
            return Some(InUse { path, build: run.build.clone(), app, bundle, pid: Some(run.pid) });
        }
        // No daemon runs: a host with a cmux app is the app's, whatever
        // else is installed, so no standalone daemon is started beside it.
        let app_bin = self.bins.iter().find(|(path, _)| app_owned(path));
        let (path, build) = app_bin.or(self.bins.first())?;
        let app = app_bin.is_some();
        Some(InUse { path: path.clone(), build: build.clone(), app, bundle: app, pid: None })
    }

    /// A cmux-tui outside an app bundle (the app's SSH install, `cmux
    /// remote install`) of build `want`, as a plain path.
    fn current_cmux_tui(&self, want: &str) -> Option<&str> {
        self.bins
            .iter()
            .find(|(path, build)| {
                is_cmux_tui(path)
                    && !app_owned(path)
                    && build.as_deref() == Some(want)
                    && hosts::plain_path(path)
            })
            .map(|(path, _)| path.as_str())
    }
}

/// Run [`probe_script`]: the running daemon says in its `daemon status`
/// what its executable is and whether it runs as `cmux-tui acp …` (no
/// process is scanned, and its command line is never read). When it does,
/// resolve [`DAEMON_BIN`] to tell enroll's own link from a cmux session
/// daemon. Reads only.
fn probe(r: &dyn Remote) -> Result<Probe> {
    let mut probe = parse_probe(&r.exec(&probe_script(), None)?.stdout);
    if probe.running.as_ref().and_then(|run| run.cmux_tui_acp) == Some(true) {
        let script = format!("readlink -f {DAEMON_BIN} 2>/dev/null");
        let stdout = r.exec(&script, None)?.stdout;
        probe.run_by_cmux_tui = cmux_session_daemon(true, probe.exe.as_deref(), stdout.trim());
    }
    Ok(probe)
}

/// Link [`DAEMON_BIN`] to `bin`: the daemon runs a cmux-tui as `acpmux`.
/// The caller holds the host's update lock and passes `r` fenced for it.
fn link_daemon_bin(r: &dyn Remote, bin: &str) -> Result<String> {
    hosts::run(
        r,
        &format!("mkdir -p ~/.local/bin && rm -f {DAEMON_BIN} && ln -s {bin} {DAEMON_BIN}"),
    )
}

/// The remote builds of `bin` and, when it is another file, of the
/// [`DAEMON_BIN`] the daemon runs; None for a binary that is not there.
fn installed(r: &dyn Remote, bin: &str) -> Result<(Option<String>, Option<String>)> {
    let mut script = format!("printf 'bin=%s\\n' \"$({} 2>/dev/null)\"", hosts::version_cmd(bin));
    if bin != DAEMON_BIN {
        script.push_str(&format!(
            "; printf 'daemon=%s\\n' \"$({} 2>/dev/null)\"",
            hosts::version_cmd(DAEMON_BIN)
        ));
    }
    let out = r.exec(&script, None)?;
    Ok(parse_installed(&out.stdout, bin != DAEMON_BIN))
}

fn parse_installed(stdout: &str, linked: bool) -> (Option<String>, Option<String>) {
    let build = |key: &str| {
        stdout.lines().find_map(|l| l.strip_prefix(key)).and_then(build_of).map(str::to_owned)
    };
    let bin = build("bin=");
    let daemon = if linked { build("daemon=") } else { bin.clone() };
    (bin, daemon)
}

/// Whether `uname -sm` names this build's OS and CPU.
fn same_platform(uname: &str, os: &str, arch: &str) -> bool {
    let mut parts = uname.split_whitespace();
    let kernel = match parts.next().unwrap_or("") {
        "Darwin" => "macos",
        "Linux" => "linux",
        other => return other.eq_ignore_ascii_case(os),
    };
    let machine = match parts.next().unwrap_or("") {
        "arm64" | "aarch64" => "aarch64",
        "x86_64" | "amd64" => "x86_64",
        other => other,
    };
    kernel == os && machine == arch
}

/// A stale peer on another platform needs a target-specific update bundle or a
/// rebuild there; plain `host update` cannot use this machine's binary.
pub(super) fn platform_skew(
    step: Step,
    host: &str,
    name: &str,
    uname: &str,
    fix: bool,
) -> Option<StepResult> {
    if uname.is_empty() || same_platform(uname, std::env::consts::OS, std::env::consts::ARCH) {
        return None;
    }
    let target = crate::cli::peer_status::target_from_uname(uname);
    let local_target =
        crate::cli::peer_status::target_triple(std::env::consts::OS, std::env::consts::ARCH);
    let fix_text = target
        .filter(|target| Some(*target) != local_target)
        .map(|target| {
            format!(
                "Run `acpmux host update {name} --binary-dir DIR` (DIR/acpmux-{target}), or rebuild acpmux on {host} for its OS and architecture (see docs/remote-agents-and-cloud.md)."
            )
        })
        .unwrap_or_else(|| {
            format!(
                "Rebuild acpmux on {host} for its OS and architecture (see docs/remote-agents-and-cloud.md)."
            )
        });
    let state = if fix { StepState::Fail } else { StepState::Warn };
    Some(
        StepResult::new(
            step,
            state,
            format!(
                "{host} is {uname}, this build is {} {}",
                std::env::consts::OS,
                std::env::consts::ARCH
            ),
        )
        .with_fix(fix_text)
        .with_reason("peer_version_skew"),
    )
}

/// The step for a host whose acpmux is cmux's own: its build is the app's
/// business, so another build only warns, and nothing is pushed.
fn app_build(step: Step, host: &str, used: &InUse, ok: &str) -> StepResult {
    let want = crate::hub::BUILD;
    match used.build.as_deref() {
        Some(b) if b == want => StepResult::new(step, StepState::Ok, ok),
        b => StepResult::new(
            step,
            StepState::Warn,
            format!("{host} runs cmux's own acpmux (build {}, this is {want})", b.unwrap_or("?")),
        )
        // A version skew: name the matching CLI, or the one way to put this
        // build there for the daemon's owner (plans/cmux-next/version-skew.md,
        // step 4): the app's own updater for a bundle, else `cmux remote
        // install` (a session daemon or the app's SSH install).
        .with_fix(match (b, used.bundle) {
            (Some(b), true) => format!(
                "Enroll {host} from a cmux of build {b}, or use cmux > Check for Updates in the cmux app on {host}."
            ),
            (None, true) => format!("Use cmux > Check for Updates in the cmux app on {host}."),
            (Some(b), false) => format!(
                "Enroll {host} from a cmux of build {b}, or run `cmux remote install` for {host}."
            ),
            (None, false) => format!("Run `cmux remote install` for {host}."),
        }),
    }
}

fn install(r: &dyn Remote, name: &str, bin: &str, fix: bool) -> StepResult {
    let host = r.host();
    let want = crate::hub::BUILD;
    let from_app = INSTALL_FROM_APP.replace("{host}", host);
    let probed = match probe(r) {
        Ok(p) => p,
        Err(e) => return fail(Step::Install, format!("{e:#}"), "Check again."),
    };
    if let Some(used) = probed.in_use().filter(|u| u.app) {
        let ok = format!("{host} runs cmux's own acpmux at {} (build {want})", used.path);
        return app_build(Step::Install, host, &used, &ok);
    }
    if !hosts::plain_path(bin) {
        return fail(
            Step::Install,
            format!("{bin} is not a plain path"),
            "Give --remote-binary as ~/… or an absolute path.",
        );
    }
    let found = match installed(r, bin) {
        Ok(found) => found,
        Err(e) => return fail(Step::Install, format!("{e:#}"), "Check again."),
    };
    // No standalone acpmux, but a cmux-tui of this build (the app installs
    // one over ssh before it runs enroll again): only the link is missing.
    let tui = (bin == DAEMON_BIN && found.0.as_deref() != Some(want))
        .then(|| probed.current_cmux_tui(want))
        .flatten()
        .map(str::to_owned);
    let (bin, found) = match &tui {
        Some(tui) => match installed(r, tui) {
            Ok(found) => (tui.as_str(), found),
            Err(e) => return fail(Step::Install, format!("{e:#}"), "Check again."),
        },
        None => (bin, found),
    };
    let describe = |(b, d): &(Option<String>, Option<String>)| match (b, d) {
        (None, _) => format!("{bin} is not installed"),
        (Some(b), _) if b != want => format!("{bin} is build {b}, this is {want}"),
        (_, None) => format!("{DAEMON_BIN} is missing"),
        (_, Some(d)) => format!("{DAEMON_BIN} is build {d}, this is {want}"),
    };
    let current = |f: &(Option<String>, Option<String>)| {
        f.0.as_deref() == Some(want) && f.1.as_deref() == Some(want)
    };
    if current(&found) {
        return StepResult::new(Step::Install, StepState::Ok, format!("{bin} is build {want}"));
    }
    let why = describe(&found);
    if !fix {
        // Another build still serves the peer link (`host ls` says it
        // differs); a missing one does not.
        if found.0.is_some() && found.1.is_some() {
            let uname = if probed.uname.is_empty() {
                match hosts::run(r, "uname -sm") {
                    Ok(u) => u,
                    Err(e) => return fail(Step::Install, format!("{e:#}"), from_app),
                }
            } else {
                probed.uname.clone()
            };
            if let Some(step) = platform_skew(Step::Install, host, name, &uname, false) {
                return step;
            }
            return StepResult::new(Step::Install, StepState::Warn, why)
                .with_fix(format!("Run `acpmux host update {name}`."))
                .with_reason("peer_version_skew")
                .with_try(format!("acpmux host update {name}"));
        }
        return fail(
            Step::Install,
            why,
            format!("Run the check with --fix to install this build on {host}."),
        );
    }
    let uname = if probed.uname.is_empty() {
        match hosts::run(r, "uname -sm") {
            Ok(u) => u,
            Err(e) => return fail(Step::Install, format!("{e:#}"), from_app),
        }
    } else {
        probed.uname.clone()
    };
    // A matching cmux-tui only needs the daemon symlink repaired; that is a
    // safe remote-only operation even when this invoking binary is for a
    // different platform. Any binary push must stop on platform skew.
    let link_only = bin != DAEMON_BIN && found.0.as_deref() == Some(want);
    if !link_only && let Some(step) = platform_skew(Step::Install, host, name, &uname, true) {
        return step;
    }
    // Every change below holds the host's update lock, so neither another
    // update nor the host's self-update timer finds its binary replaced under it.
    let lock = match hosts::lock_to_install(r) {
        Ok(lock) => lock,
        Err(e) => {
            return fail(Step::Install, format!("{why}; {e:#}"), "Check again once it ended.");
        }
    };
    let fenced = lock.fence(r);
    let r: &dyn Remote = &fenced;
    // `bin` is this build and only the link is missing or stale: link it,
    // before anything that needs this program to match the host.
    if bin != DAEMON_BIN && found.0.as_deref() == Some(want) {
        return match link_daemon_bin(r, bin).and_then(|_| installed(r, bin)) {
            Ok(after) if current(&after) => StepResult::new(
                Step::Install,
                StepState::Fixed,
                format!("{why}; linked {DAEMON_BIN} to {bin}"),
            ),
            Ok(after) => {
                fail(Step::Install, format!("after linking, {}", describe(&after)), from_app)
            }
            Err(e) => fail(Step::Install, format!("{why}; linking failed: {e:#}"), from_app),
        };
    }
    // cmux-tui runs as acpmux under that name; a standalone acpmux cannot
    // stand in for the app's cmux-tui.
    let exe = crate::self_command::SelfCommand::current().ok().map(|c| c.exe);
    let exe_name =
        exe.as_deref().and_then(Path::file_name).map(|n| n.to_string_lossy().into_owned());
    let bin_name = bin.rsplit('/').next().unwrap_or(bin);
    if bin_name != "acpmux" && exe_name.as_deref() != Some(bin_name) {
        return fail(
            Step::Install,
            format!("{why}; this program cannot replace {bin_name}"),
            from_app,
        )
        .with_reason(REASON_NOT_THIS_PROGRAM);
    }
    let pushed = hosts::push_binary(r, bin).and_then(|_| {
        if bin == DAEMON_BIN {
            return Ok(String::new());
        }
        link_daemon_bin(r, bin)
    });
    if let Err(e) = pushed {
        return fail(Step::Install, format!("{why}; the push failed: {e:#}"), from_app);
    }
    match installed(r, bin) {
        Ok(after) if current(&after) => {
            StepResult::new(Step::Install, StepState::Fixed, format!("{why}; pushed build {want}"))
        }
        Ok(after) => fail(Step::Install, format!("after the push, {}", describe(&after)), from_app),
        Err(e) => fail(Step::Install, format!("after the push: {e:#}"), from_app),
    }
}

/// `text` with the local home `from` rewritten to the remote `to` wherever
/// it is a whole path prefix (`/Users/leo` but not `/Users/leonard`).
fn rewrite_home(text: &str, from: &str, to: &str) -> String {
    let from = from.trim_end_matches('/');
    if from.is_empty() || from == to {
        return text.to_owned();
    }
    let path_byte = |b: u8| b.is_ascii_alphanumeric() || b"._-/".contains(&b);
    let bytes = text.as_bytes();
    let (mut out, mut last) = (String::with_capacity(text.len()), 0);
    for (at, _) in text.match_indices(from) {
        let prev = at.checked_sub(1).map(|i| bytes[i]);
        let next = bytes.get(at + from.len()).copied();
        if prev.is_some_and(path_byte) || next.is_some_and(|b| b != b'/' && path_byte(b)) {
            continue;
        }
        out.push_str(&text[last..at]);
        out.push_str(to);
        last = at + from.len();
    }
    out.push_str(&text[last..]);
    out
}

/// Whether an `ls -lnL` line shows a file the profile loader accepts: a
/// regular file of `uid` that neither group nor others can write
/// (`read_profile_file` in config/profiles.rs).
fn profile_perms(ls: &str, uid: &str) -> Result<(), &'static str> {
    let mut fields = ls.split_whitespace();
    let mode = fields.next().unwrap_or("").as_bytes();
    let owner = fields.nth(1).unwrap_or("");
    if mode.len() < 10 || mode[0] != b'-' {
        return Err("not a regular file");
    }
    if owner != uid {
        return Err("owned by another user");
    }
    if mode[5] == b'w' || mode[8] == b'w' {
        return Err("group- or other-writable, so acpmux refuses it");
    }
    Ok(())
}

/// Why the remote copy of profile `id` is not `want`, or None.
fn remote_profile_problem(r: &dyn Remote, id: &str, want: &str) -> Result<Option<String>> {
    let script = format!(
        "{REMOTE_HARNESS_DIR}; f=\"$d/{id}.toml\"; id -u; ls -lnL \"$f\" 2>/dev/null; printf '\\0'; cat \"$f\" 2>/dev/null"
    );
    let out = r.exec(&script, None)?;
    let (head, body) = out.stdout.split_once('\0').unwrap_or((&out.stdout, ""));
    let mut lines = head.lines();
    let uid = lines.next().unwrap_or("").trim();
    let Some(ls) = lines.next().filter(|l| !l.trim().is_empty()) else {
        return Ok(Some("missing".into()));
    };
    if let Err(why) = profile_perms(ls, uid) {
        return Ok(Some(why.into()));
    }
    let sha = crate::sha256::sha256_hex;
    Ok((sha(body.as_bytes()) != sha(want.as_bytes())).then(|| "differs".into()))
}

/// Write profile `id` into the remote harness folder: the text over stdin,
/// the folder 700 and the file 600, replaced in one rename.
fn write_profile(r: &dyn Remote, id: &str, text: &str) -> Result<()> {
    let script = format!(
        "{REMOTE_HARNESS_DIR}; mkdir -p \"$d\" && chmod 700 \"$d\" && umask 077 && cat > \"$d/{id}.toml.new\" && chmod 600 \"$d/{id}.toml.new\" && mv -f \"$d/{id}.toml.new\" \"$d/{id}.toml\""
    );
    let out = r.exec(&script, Some(text.as_bytes()))?;
    if !out.ok {
        anyhow::bail!("writing {id}.toml on {} failed: {}", r.host(), out.stderr.trim());
    }
    Ok(())
}

/// One profile: Ok(None) when the host has it, Ok(Some(why)) when it was
/// repaired, Err(why) when it is still wrong.
fn harness_one(
    r: &dyn Remote,
    id: &str,
    local: &Local,
    remote_home: &str,
    fix: bool,
) -> Result<Option<String>, String> {
    if !crate::config::profiles::valid_id(id) {
        return Err("not a harness id".into());
    }
    let dir = local.harness_dir.as_deref().ok_or("this machine has no harness folder")?;
    let path = dir.join(format!("{id}.toml"));
    let text = std::fs::read_to_string(&path).map_err(|_| format!("no {}", path.display()))?;
    let home = local.home.as_deref().map(|h| h.to_string_lossy().into_owned()).unwrap_or_default();
    let want = rewrite_home(&text, &home, remote_home);
    let problem = match remote_profile_problem(r, id, &want) {
        Ok(None) => return Ok(None),
        Ok(Some(problem)) => problem,
        Err(e) => return Err(format!("{e:#}")),
    };
    if !fix {
        return Err(problem);
    }
    write_profile(r, id, &want).map_err(|e| format!("{problem}; {e:#}"))?;
    match remote_profile_problem(r, id, &want) {
        Ok(None) => Ok(Some(problem)),
        Ok(Some(after)) => Err(format!("{problem}; after the copy, {after}")),
        Err(e) => Err(format!("{problem}; {e:#}")),
    }
}

/// A host may have a catalog harness discovered from PATH even when this
/// client has no profile file to copy. That is a usable remote harness; the
/// real session check belongs to `new --host`, not to profile synchronization.
fn remote_harness_discovered(r: &dyn Remote, id: &str) -> bool {
    let command = probe(r)
        .ok()
        .and_then(|p| p.in_use().map(|u| u.path))
        .unwrap_or_else(|| DAEMON_BIN.to_owned());
    let command = if command.rsplit('/').next() == Some("acpmux") {
        format!("{} --json daemon harnesses", shell_quote(&command))
    } else {
        format!("{} acp --json daemon harnesses", shell_quote(&command))
    };
    let Ok(out) = hosts::run(r, &command) else {
        return false;
    };
    let Ok(value) = serde_json::from_str::<Value>(&out) else { return false };
    value
        .get("harnesses")
        .and_then(|harnesses| harnesses.get(id))
        .is_some_and(|profile| profile.get("unavailable").is_none())
}

fn harness(
    r: &dyn Remote,
    peer_name: &str,
    ids: &[String],
    local: &Local,
    fix: bool,
) -> StepResult {
    if ids.is_empty() {
        return StepResult::new(Step::Harness, StepState::Skip, "no --harness given");
    }
    let remote_home = match hosts::run(r, "printf %s \"$HOME\"") {
        Ok(h) if h.starts_with('/') => h,
        Ok(h) => {
            return fail(
                Step::Harness,
                format!("the remote home {h:?} is not a path"),
                "Check $HOME on the host.",
            );
        }
        Err(e) => return fail(Step::Harness, format!("{e:#}"), "Check again."),
    };
    let (mut parts, mut failed, mut fixed) = (Vec::new(), false, false);
    for id in ids {
        let local_profile = local
            .harness_dir
            .as_deref()
            .map(|dir| dir.join(format!("{id}.toml")).is_file())
            .unwrap_or(false);
        if !local_profile && remote_harness_discovered(r, id) {
            parts.push(format!(
                "{id} discovered on the host (profile copy skipped; verify with `acpmux new --host {peer_name} -m {id} -d`) ",
            ));
            continue;
        }
        match harness_one(r, id, local, &remote_home, fix) {
            Ok(None) => parts.push(format!("{id} ok")),
            Ok(Some(why)) => {
                fixed = true;
                parts.push(format!("{id} copied ({why})"));
            }
            Err(why) => {
                failed = true;
                parts.push(format!("{id}: {why}"));
            }
        }
    }
    let detail = parts.join("; ");
    if failed {
        let host = r.host();
        let hint = if fix {
            format!(
                "Check that each profile exists in this machine's harness folder and that {host}'s harness folder is writable."
            )
        } else {
            format!("Run the check with --fix to copy the profiles to {host}.")
        };
        return fail(Step::Harness, detail, hint);
    }
    StepResult::new(Step::Harness, if fixed { StepState::Fixed } else { StepState::Ok }, detail)
}

#[cfg(test)]
#[path = "host_enroll_tests.rs"]
mod tests;
