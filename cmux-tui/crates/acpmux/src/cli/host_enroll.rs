//! `acpmux host enroll` and `host doctor`: the Add Machine checklist
//! (plans/cmux-next/add-machine-DESIGN.md). Each step checks the machine
//! and, with `fix` (always on for enroll), repairs what its check found; a
//! step whose dependency did not pass is `skip`. One JSON line per step as
//! it finishes, then `{"report":{...}}`. Without `fix` nothing changes.

use crate::cli::errors::{AppError, Code};
use crate::cli::host_peering::{self, PeerTarget};
use crate::cli::host_steps::{
    REASON_NOT_THIS_PROGRAM, REASON_WRONG_PLATFORM, Report, Step, StepResult, StepState,
};
use crate::cli::hosts::{self, DAEMON_BIN, Remote, SshRemote};
use crate::client::Client;
use anyhow::Result;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// The machine enroll or doctor works on.
pub(crate) struct Plan {
    pub name: String,
    pub host: String,
    /// The remote daemon's WebSocket port (the peer url's).
    pub port: u16,
    pub harnesses: Vec<String>,
    /// The remote binary `install` checks and pushes; when it is not
    /// [`DAEMON_BIN`], that path becomes a link to it.
    pub remote_binary: String,
    /// Run `peer-back` (`--reverse`); off by default, it is reported `skip`.
    pub reverse: bool,
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
    let mut done = machine_steps(&remote, &plan, &local, fix, &mut emit);
    let local_name = hosts::short_name(&crate::hand::pair::hostname());
    let t = PeerTarget {
        name: &plan.name,
        host: &plan.host,
        port: plan.port,
        local_name: &local_name,
        local_dest: None,
    };
    for step in [Step::Peer, Step::PeerBack, Step::Identity] {
        let result = match gate(step, &done) {
            Some(skip) => skip,
            None => match step {
                Step::Peer => host_peering::peer(&client, &t, fix).await,
                Step::PeerBack if !plan.reverse => peer_back_off(),
                Step::PeerBack => host_peering::peer_back(&t, fix).await,
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
        return Err(AppError::new(Code::Runtime, "unhealthy", why).into());
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
/// name, else the peer at that ssh host, else the host itself.
pub(crate) fn pick_target(peers: &[Value], target: &str) -> (String, String, u16) {
    let ssh_peers = peers.iter().filter_map(|p| {
        let name = p.get("name").and_then(Value::as_str)?;
        let t = crate::peer::ssh_target(p.get("url").and_then(Value::as_str)?).ok()?;
        Some((name.to_owned(), t.destination, t.port))
    });
    let ssh_peers: Vec<_> = ssh_peers.collect();
    ssh_peers
        .iter()
        .find(|(name, _, _)| name == target)
        .or_else(|| ssh_peers.iter().find(|(_, host, _)| host == target))
        .cloned()
        .unwrap_or_else(|| {
            (hosts::short_name(target), target.to_owned(), crate::peer::SSH_PEER_PORT)
        })
}

/// reach, install, daemon and harness: the steps on the machine itself.
fn machine_steps(
    r: &dyn Remote,
    plan: &Plan,
    local: &Local,
    fix: bool,
    emit: &mut dyn FnMut(&StepResult),
) -> Vec<StepResult> {
    let mut done = Vec::new();
    for step in [Step::Reach, Step::Install, Step::Daemon, Step::Harness] {
        let result = gate(step, &done).unwrap_or_else(|| match step {
            Step::Reach => reach(r),
            Step::Install => install(r, &plan.name, &plan.remote_binary, fix),
            Step::Daemon => daemon(r, &plan.name, plan.port, fix),
            _ => harness(r, &plan.harnesses, local, fix),
        });
        emit(&result);
        done.push(result);
    }
    done
}

/// The steps that must have passed before this one runs. A skipped step
/// blocks too, so a failure skips everything downstream of it.
fn needs(step: Step) -> &'static [Step] {
    match step {
        Step::Reach => &[],
        Step::Install | Step::Identity => &[Step::Reach],
        Step::Daemon => &[Step::Install],
        Step::Harness | Step::Peer | Step::PeerBack => &[Step::Daemon],
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
    StepResult::new(step, StepState::Fail, detail).with_fix(fix)
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
/// with its version line and what `daemon status` (which never starts a
/// daemon) says through it (a cmux-tui as `cmux-tui acp …`); then a NUL and
/// the daemon config. An app name may hold spaces: the glob's words stay
/// whole and a pattern that matched nothing fails `-f`.
const PROBE_BINS: &str = r#"seen=; for b in "$(command -v acpmux 2>/dev/null)" ~/.local/bin/acpmux /Applications/cmux*.app/Contents/Resources/bin/acpmux ~/.local/bin/cmux-tui ~/.cmux/bin/cmux-tui "$(command -v cmux-tui 2>/dev/null)"; do [ -n "$b" ] && [ -f "$b" ] && [ -x "$b" ] || continue; case "$seen" in *"|$b|"*) continue ;; esac; seen="$seen|$b|"; case "$b" in */acpmux) set -- "$b" ;; *) set -- "$b" acp ;; esac; printf 'bin\t%s\t%s\n' "$b" "$("$@" --version 2>/dev/null | head -n 1)"; printf 'status\t%s\t%s\n' "$b" "$("$@" --json daemon status 2>/dev/null | tr -d '\n')"; done; printf '\0'; "#;

/// [`PROBE_BINS`], then the remote daemon config.
fn probe_script() -> String {
    format!("{PROBE_BINS}cat {}/config.json 2>/dev/null", hosts::REMOTE_HOME)
}

/// What [`probe_script`] found.
#[derive(Debug, Default, PartialEq, Eq)]
struct Probe {
    /// Each acpmux on the host and its build, in [`probe_script`] order.
    bins: Vec<(String, Option<String>)>,
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
        let mut parts = line.splitn(3, '\t');
        let (Some(kind), Some(path), rest) = (parts.next(), parts.next(), parts.next()) else {
            continue;
        };
        let rest = rest.unwrap_or("");
        match kind {
            "bin" => probe.bins.push((path.to_owned(), build_of(rest).map(str::to_owned))),
            "status" if probe.running.is_none() => {
                let v: Value = serde_json::from_str(rest.trim()).unwrap_or(Value::Null);
                if let Some(pid) = v.get("pid").and_then(Value::as_u64) {
                    probe.running = Some(Running {
                        via: path.to_owned(),
                        pid,
                        build: v.get("build").and_then(Value::as_str).map(str::to_owned),
                        person_key: v.get("personKey").and_then(Value::as_bool) == Some(true),
                        cmux_tui_acp: v.get("runsAsCmuxTuiAcp").and_then(Value::as_bool),
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
    let tui = (bin == DAEMON_BIN && found.0.is_none())
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
            return StepResult::new(Step::Install, StepState::Warn, why)
                .with_fix(format!("Run `acpmux host update {name}`."));
        }
        return fail(
            Step::Install,
            why,
            format!("Run the check with --fix to install this build on {host}."),
        );
    }
    // Every change below holds the host's update lock, so no other update
    // of the host finds its binary replaced under it.
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
    let uname = match hosts::run(r, "uname -sm") {
        Ok(u) => u,
        Err(e) => return fail(Step::Install, format!("{why}; {e:#}"), from_app),
    };
    let (os, arch) = (std::env::consts::OS, std::env::consts::ARCH);
    if !same_platform(&uname, os, arch) {
        return fail(
            Step::Install,
            format!("{why}; {host} is {uname}, this build is {os} {arch}"),
            from_app,
        )
        .with_reason(REASON_WRONG_PLATFORM);
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

/// Why the config gives the peer link no WebSocket listener on `port`.
fn listener_problem(config: &str, port: u16) -> Option<String> {
    let cfg: Value = serde_json::from_str(config).unwrap_or(Value::Null);
    let listen = cfg.pointer("/websocket/listen").and_then(Value::as_str);
    let has_token =
        cfg.pointer("/websocket/token").and_then(Value::as_str).is_some_and(|t| !t.is_empty());
    match listen {
        None => Some("no WebSocket listener is configured".into()),
        Some(_) if !has_token => Some("the WebSocket listener has no token".into()),
        Some(l) if !l.ends_with(&format!(":{port}")) => {
            Some(format!("the daemon listens on {l}, the peer uses port {port}"))
        }
        Some(_) => None,
    }
}

/// The daemon of the acpmux the host uses, judged.
#[derive(Debug)]
enum Verdict {
    /// Nothing to repair from here: ours and current, or cmux's own.
    Done(StepResult),
    /// Ours, of another build: it serves the peer link, a restart updates it.
    OtherBuild(StepResult),
    /// Ours and not usable: why.
    Repair(String),
}

fn judge_daemon(host: &str, name: &str, probe: &Probe, port: u16) -> Verdict {
    let want = crate::hub::BUILD;
    let used = probe.in_use();
    if let Some(used) = used.as_ref().filter(|u| u.app) {
        // cmux owns this daemon: never start, configure or restart it here.
        let Some(pid) = used.pid else {
            return Verdict::Done(fail(
                Step::Daemon,
                format!("cmux is installed on {host} but its acpmux daemon is not running"),
                format!("Open cmux on {host}, then check again."),
            ));
        };
        if let Some(why) = listener_problem(&probe.config, port) {
            return Verdict::Done(fail(
                Step::Daemon,
                format!("cmux's own daemon runs on {host}, but {why}"),
                format!(
                    "Give the daemon a WebSocket listener on 127.0.0.1:{port} with a token in {}/config.json on {host}, then restart cmux there.",
                    hosts::REMOTE_HOME
                ),
            ));
        }
        let ok = format!("cmux's own daemon runs, pid {pid}, build {want}");
        return Verdict::Done(app_build(Step::Daemon, host, used, &ok));
    }
    if let Some(why) = listener_problem(&probe.config, port) {
        return Verdict::Repair(why);
    }
    let Some(pid) = used.as_ref().and_then(|u| u.pid) else {
        return Verdict::Repair("the daemon is not running".into());
    };
    match used.and_then(|u| u.build) {
        Some(b) if b != want => Verdict::OtherBuild(
            StepResult::new(
                Step::Daemon,
                StepState::Warn,
                format!("the daemon runs build {b}, this is {want}"),
            )
            .with_fix(format!("Run `acpmux host update {name}`.")),
        ),
        _ => Verdict::Done(StepResult::new(
            Step::Daemon,
            StepState::Ok,
            format!("running, pid {pid}, build {want}"),
        )),
    }
}

fn daemon(r: &dyn Remote, name: &str, port: u16, fix: bool) -> StepResult {
    let host = r.host();
    let judge = |r: &dyn Remote| match probe(r) {
        Ok(p) => judge_daemon(host, name, &p, port),
        Err(e) => Verdict::Repair(format!("{e:#}")),
    };
    let why = match judge(r) {
        Verdict::Done(result) => return result,
        Verdict::OtherBuild(result) if !fix => return result,
        Verdict::OtherBuild(result) => result.detail,
        Verdict::Repair(why) => why,
    };
    let look = format!("Run `{DAEMON_BIN} daemon start` on {host} to see why it does not start.");
    if !fix {
        return fail(
            Step::Daemon,
            why,
            format!("Run the check with --fix to configure and start the daemon on {host}."),
        );
    }
    let started = hosts::lock_to_install(r)
        .and_then(|lock| hosts::install_daemon(&lock.fence(r), port, true));
    if let Err(e) = started {
        return fail(Step::Daemon, format!("{why}; starting it failed: {e:#}"), look);
    }
    match judge(r) {
        Verdict::Done(after) if after.state == StepState::Ok => {
            StepResult::new(Step::Daemon, StepState::Fixed, format!("{why}; now {}", after.detail))
        }
        Verdict::Done(after) | Verdict::OtherBuild(after) => {
            fail(Step::Daemon, format!("{why}; after a restart, {}", after.detail), look)
        }
        Verdict::Repair(after) => {
            fail(Step::Daemon, format!("{why}; after a restart, {after}"), look)
        }
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
        let prev = at.checked_sub(1).and_then(|i| bytes.get(i)).copied();
        let next = bytes.get(at + from.len()).copied();
        if prev.is_some_and(path_byte) || next.is_some_and(|b| b != b'/' && path_byte(b)) {
            continue;
        }
        // Matches do not overlap and start and end on character boundaries.
        let Some(kept) = text.get(last..at) else { continue };
        out.push_str(kept);
        out.push_str(to);
        last = at + from.len();
    }
    if let Some(tail) = text.get(last..) {
        out.push_str(tail);
    }
    out
}

/// Whether an `ls -lnL` line shows a file the profile loader accepts: a
/// regular file of `uid` that neither group nor others can write
/// (`read_profile_file` in config/profiles.rs).
fn profile_perms(ls: &str, uid: &str) -> Result<(), &'static str> {
    let mut fields = ls.split_whitespace();
    let mode = fields.next().unwrap_or("").as_bytes();
    let owner = fields.nth(1).unwrap_or("");
    let [b'-', _, _, _, _, group_write, _, _, other_write, _, ..] = mode else {
        return Err("not a regular file");
    };
    if owner != uid {
        return Err("owned by another user");
    }
    if *group_write == b'w' || *other_write == b'w' {
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

fn harness(r: &dyn Remote, ids: &[String], local: &Local, fix: bool) -> StepResult {
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
