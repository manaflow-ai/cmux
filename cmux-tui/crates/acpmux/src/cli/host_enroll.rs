//! `acpmux host enroll` and `host doctor`: the Add Machine checklist
//! (plans/cmux-next/add-machine-DESIGN.md). Each step checks the machine
//! and, with `fix` (always on for enroll), repairs what its check found; a
//! step whose dependency did not pass is `skip`. One JSON line per step as
//! it finishes, then `{"report":{...}}`. Without `fix` nothing changes.

use crate::cli::host_peering::{self, PeerTarget};
use crate::cli::host_steps::{Report, Step, StepResult, StepState};
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

pub(crate) async fn run(client: Arc<Client>, plan: Plan, fix: bool, json_out: bool) -> Result<()> {
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
        local_name: &local_name,
        local_dest: None,
    };
    for step in [Step::Peer, Step::PeerBack, Step::Identity] {
        let result = match gate(step, &done) {
            Some(skip) => skip,
            None => match step {
                Step::Peer => host_peering::peer(&client, &t, fix).await,
                Step::PeerBack if !plan.reverse => {
                    StepResult::new(Step::PeerBack, StepState::Skip, "--no-reverse")
                }
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
        std::process::exit(1);
    }
    Ok(())
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
            Step::Install => install(r, &plan.remote_binary, fix),
            Step::Daemon => daemon(r, plan.port, fix),
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
            Self::NoRoute => format!(
                "Check the name {bare}, that the machine is on, and that it is on this network or tailnet."
            ),
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

fn install(r: &dyn Remote, bin: &str, fix: bool) -> StepResult {
    let host = r.host();
    let want = crate::hub::BUILD;
    let from_app = INSTALL_FROM_APP.replace("{host}", host);
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
        return fail(
            Step::Install,
            why,
            format!("Run the check with --fix to install this build on {host}."),
        );
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
        );
    }
    // cmux-tui runs as acpmux under that name; a standalone acpmux cannot
    // stand in for the app's cmux-tui.
    let exe = std::env::current_exe().ok();
    let exe_name =
        exe.as_deref().and_then(Path::file_name).map(|n| n.to_string_lossy().into_owned());
    let bin_name = bin.rsplit('/').next().unwrap_or(bin);
    if bin_name != "acpmux" && exe_name.as_deref() != Some(bin_name) {
        return fail(
            Step::Install,
            format!("{why}; this program cannot replace {bin_name}"),
            from_app,
        );
    }
    let pushed = hosts::push_binary(r, bin).and_then(|_| {
        if bin == DAEMON_BIN {
            return Ok(String::new());
        }
        hosts::run(
            r,
            &format!("mkdir -p ~/.local/bin && rm -f {DAEMON_BIN} && ln -s {bin} {DAEMON_BIN}"),
        )
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

/// Whether the remote daemon answers as this build with a WebSocket
/// listener on `port`: what it reports, or why not.
fn judge_daemon(config: &str, status: &str, port: u16, want: &str) -> Result<String, String> {
    let cfg: Value = serde_json::from_str(config).unwrap_or(Value::Null);
    let listen = cfg.pointer("/websocket/listen").and_then(Value::as_str);
    let has_token =
        cfg.pointer("/websocket/token").and_then(Value::as_str).is_some_and(|t| !t.is_empty());
    match listen {
        None => return Err("no WebSocket listener is configured".into()),
        Some(_) if !has_token => return Err("the WebSocket listener has no token".into()),
        Some(l) if !l.ends_with(&format!(":{port}")) => {
            return Err(format!("the daemon listens on {l}, the peer uses port {port}"));
        }
        Some(_) => {}
    }
    let status: Value = serde_json::from_str(status.trim()).unwrap_or(Value::Null);
    if status.get("pid").is_none() {
        return Err("the daemon is not running".into());
    }
    match status.get("build").and_then(Value::as_str) {
        Some(b) if b != want => Err(format!("the daemon runs build {b}, this is {want}")),
        _ => Ok(format!(
            "running, pid {}, build {want}",
            status.get("pid").and_then(Value::as_u64).unwrap_or(0)
        )),
    }
}

fn daemon_state(r: &dyn Remote, port: u16) -> Result<String, String> {
    let script = format!(
        "cat ~/.acpmux/config.json 2>/dev/null; printf '\\0'; {DAEMON_BIN} --json daemon status 2>/dev/null"
    );
    let out = r.exec(&script, None).map_err(|e| format!("{e:#}"))?;
    let (config, status) = out.stdout.split_once('\0').unwrap_or((&out.stdout, ""));
    judge_daemon(config, status, port, crate::hub::BUILD)
}

fn daemon(r: &dyn Remote, port: u16, fix: bool) -> StepResult {
    let host = r.host();
    let why = match daemon_state(r, port) {
        Ok(detail) => return StepResult::new(Step::Daemon, StepState::Ok, detail),
        Err(why) => why,
    };
    let look = format!("Run `{DAEMON_BIN} daemon start` on {host} to see why it does not start.");
    if !fix {
        return fail(
            Step::Daemon,
            why,
            format!("Run the check with --fix to configure and start the daemon on {host}."),
        );
    }
    if let Err(e) = hosts::install_daemon(r, port, true) {
        return fail(Step::Daemon, format!("{why}; starting it failed: {e:#}"), look);
    }
    match daemon_state(r, port) {
        Ok(detail) => {
            StepResult::new(Step::Daemon, StepState::Fixed, format!("{why}; now {detail}"))
        }
        Err(after) => fail(Step::Daemon, format!("{why}; after a restart, {after}"), look),
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
mod tests {
    use super::*;
    use crate::cli::hosts::RemoteOut;
    use std::cell::RefCell;

    /// A host that answers each script through `answer` and logs every
    /// call; `push` only records.
    struct Fake<F: Fn(&str, Option<&[u8]>) -> RemoteOut> {
        answer: F,
        calls: RefCell<Vec<(String, bool)>>,
        pushes: RefCell<Vec<String>>,
    }

    impl<F: Fn(&str, Option<&[u8]>) -> RemoteOut> Fake<F> {
        fn new(answer: F) -> Self {
            Self { answer, calls: RefCell::default(), pushes: RefCell::default() }
        }
    }

    impl<F: Fn(&str, Option<&[u8]>) -> RemoteOut> Remote for Fake<F> {
        fn host(&self) -> &str {
            "leo@box.tail"
        }
        fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut> {
            self.calls.borrow_mut().push((script.to_owned(), stdin.is_some()));
            Ok((self.answer)(script, stdin))
        }
        fn push(&self, _local: &Path, remote: &str) -> Result<()> {
            self.pushes.borrow_mut().push(remote.to_owned());
            Ok(())
        }
    }

    fn out(stdout: impl Into<String>) -> RemoteOut {
        RemoteOut { ok: true, stdout: stdout.into(), stderr: String::new() }
    }

    fn version(build: &str) -> String {
        format!("bin=acpmux 0.1.0 ({build})\n")
    }

    const CONFIG: &str = r#"{"websocket":{"listen":"127.0.0.1:47811","token":"t"}}"#;

    fn status(build: &str) -> String {
        format!("{CONFIG}\0{{\"pid\": 7, \"build\": \"{build}\"}}")
    }

    fn plan(harnesses: &[&str]) -> Plan {
        Plan {
            name: "box".into(),
            host: "leo@box.tail".into(),
            port: 47811,
            harnesses: harnesses.iter().map(|s| s.to_string()).collect(),
            remote_binary: DAEMON_BIN.into(),
            reverse: true,
        }
    }

    /// A local harness folder with profile `id` mentioning the local home.
    fn local_with(tag: &str, id: &str, text: &str) -> Local {
        let dir = std::env::temp_dir().join(format!("acpmux-enroll-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(format!("{id}.toml")), text).unwrap();
        Local { harness_dir: Some(dir), home: Some(PathBuf::from("/Users/leo")) }
    }

    fn states(results: &[StepResult]) -> Vec<(Step, StepState)> {
        results.iter().map(|r| (r.step, r.state)).collect()
    }

    #[test]
    fn ssh_stderr_is_classified() {
        let cases = [
            (
                "ssh: Could not resolve hostname nope: nodename nor servname provided, or not known",
                SshFailure::NoRoute,
            ),
            ("ssh: connect to host 10.0.0.9 port 22: No route to host", SshFailure::NoRoute),
            ("ssh: connect to host box port 22: Operation timed out", SshFailure::NoRoute),
            ("ssh: connect to host box port 22: Connection refused", SshFailure::SshOff),
            ("leo@box: Permission denied (publickey,password).", SshFailure::KeyRejected),
            (
                "@@@@@@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n@@@@@@@@@@@\nHost key verification failed.",
                SshFailure::HostKeyChanged,
            ),
            (
                "No ED25519 host key is known for box and you have requested strict checking.\nHost key verification failed.",
                SshFailure::HostKeyChanged,
            ),
            ("kex_exchange_identification: read: Connection reset by peer", SshFailure::Other),
        ];
        for (stderr, want) in cases {
            assert_eq!(SshFailure::of(stderr), want, "{stderr}");
        }
        assert!(SshFailure::KeyRejected.fix("leo@box").contains("ssh-copy-id leo@box"));
        assert!(SshFailure::HostKeyChanged.fix("leo@box").contains("ssh-keygen -R box"));
    }

    #[test]
    fn a_failure_skips_what_depends_on_it() {
        let r = |step, state| StepResult::new(step, state, "");
        // Reach failed: everything after it is skipped, transitively.
        let mut done = vec![r(Step::Reach, StepState::Fail)];
        for step in
            [Step::Install, Step::Daemon, Step::Harness, Step::Peer, Step::PeerBack, Step::Identity]
        {
            let skip = gate(step, &done).expect("skipped");
            assert_eq!(skip.state, StepState::Skip);
            done.push(skip);
        }
        assert_eq!(done[1].detail, "needs reach");
        assert_eq!(done[2].detail, "needs install");
        assert_eq!(done[3].detail, "needs daemon");
        // Install failed: daemon and what needs it skip; identity still runs.
        let done = vec![r(Step::Reach, StepState::Ok), r(Step::Install, StepState::Fail)];
        assert!(gate(Step::Daemon, &done).is_some());
        assert!(gate(Step::Identity, &done).is_none());
        // Fixed and warn pass; a harness not asked for blocks nothing.
        let done = vec![
            r(Step::Reach, StepState::Ok),
            r(Step::Install, StepState::Fixed),
            r(Step::Daemon, StepState::Ok),
            r(Step::Harness, StepState::Skip),
        ];
        assert!(gate(Step::Daemon, &done).is_none());
        assert!(gate(Step::Peer, &done).is_none());
    }

    #[test]
    fn the_local_home_is_rewritten_only_as_a_whole_prefix() {
        let text = "command = \"/Users/leo/bin/agent\"\ncwd = '/Users/leo'\nother = \"/Users/leonard/x\"\nnested = \"/opt/Users/leo/y\"\n";
        assert_eq!(
            rewrite_home(text, "/Users/leo", "/home/leo"),
            "command = \"/home/leo/bin/agent\"\ncwd = '/home/leo'\nother = \"/Users/leonard/x\"\nnested = \"/opt/Users/leo/y\"\n"
        );
        assert_eq!(rewrite_home("x", "", "/home/leo"), "x");
        assert_eq!(rewrite_home("/Users/leo/a", "/Users/leo/", "/home/l"), "/home/l/a");
    }

    #[test]
    fn a_profile_others_can_write_is_refused() {
        assert_eq!(
            profile_perms("-rw-------  1 501  20  12 Oct 20 12:00 /h/x.toml", "501"),
            Ok(())
        );
        assert_eq!(
            profile_perms("-rw-r--r--@ 1 501  20  12 Oct 20 12:00 /h/x.toml", "501"),
            Ok(())
        );
        assert!(profile_perms("-rw-rw-r--  1 501  20  12 Oct 20 12:00 /h/x.toml", "501").is_err());
        assert!(profile_perms("-rw----rw-  1 501  20  12 Oct 20 12:00 /h/x.toml", "501").is_err());
        assert_eq!(
            profile_perms("-rw-------  1 0  0  12 Oct 20 12:00 /h/x.toml", "501"),
            Err("owned by another user")
        );
        assert_eq!(
            profile_perms("drwx------  2 501 20 64 Oct 20 12:00 /h/x.toml", "501"),
            Err("not a regular file")
        );
    }

    #[test]
    fn a_name_defaults_to_the_short_host_and_doctor_finds_peers() {
        assert_eq!(hosts::short_name("leo@huge-blue.tail1234.ts.net"), "huge-blue");
        assert_eq!(hosts::short_name("cmux16"), "cmux16");
        let peers = vec![
            json!({"name": "hb", "url": "ssh://leo@huge-blue.tail:47900"}),
            json!({"name": "web", "url": "ws://10.0.0.2:47811"}),
        ];
        assert_eq!(pick_target(&peers, "hb"), ("hb".into(), "leo@huge-blue.tail".into(), 47900));
        assert_eq!(
            pick_target(&peers, "leo@huge-blue.tail"),
            ("hb".into(), "leo@huge-blue.tail".into(), 47900)
        );
        assert_eq!(pick_target(&peers, "web"), ("web".into(), "web".into(), 47811));
        assert_eq!(pick_target(&peers, "box.lan"), ("box".into(), "box.lan".into(), 47811));
    }

    #[test]
    fn version_and_platform_parsing() {
        assert_eq!(build_of("acpmux 0.1.0 (abc123 2026-10-20)"), Some("abc123 2026-10-20"));
        assert_eq!(build_of("acpmux 0.1.0"), None);
        assert_eq!(
            parse_installed("bin=acpmux 1 (a)\n", false),
            (Some("a".into()), Some("a".into()))
        );
        assert_eq!(
            parse_installed("bin=cmux acp 1 (a)\ndaemon=\n", true),
            (Some("a".into()), None)
        );
        assert!(same_platform("Darwin arm64", "macos", "aarch64"));
        assert!(same_platform("Linux x86_64", "linux", "x86_64"));
        assert!(!same_platform("Linux aarch64", "macos", "aarch64"));
        assert!(!same_platform("Darwin x86_64", "macos", "aarch64"));
    }

    #[test]
    fn json_lines_have_the_contract_shape() {
        let step =
            StepResult::new(Step::Reach, StepState::Fail, "no route").with_fix("check the name");
        let line = step_line(&step);
        assert!(!line.contains('\n'));
        let v: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(
            v,
            json!({"step": "reach", "state": "fail", "detail": "no route", "fix": "check the name"})
        );
        let report = Report::new("box", "leo@box", vec![step]);
        let v: Value = serde_json::from_str(&report_line(&report)).unwrap();
        assert_eq!(v["report"]["name"], "box");
        assert_eq!(v["report"]["host"], "leo@box");
        assert_eq!(v["report"]["ok"], false);
        assert_eq!(v["report"]["steps"][0]["step"], "reach");
        assert!(v["report"]["steps"][0].get("fix").is_some());
    }

    #[test]
    fn doctor_without_fix_changes_nothing() {
        let build = crate::hub::BUILD;
        let local = local_with("nofix", "pi", "command = \"/Users/leo/bin/pi\"\n");
        // Old build on the host; a stopped daemon; a stale profile.
        let scenarios: [(&str, &str, &str); 3] =
            [("old", build, build), (build, "old", build), (build, build, "stale")];
        for (bin, daemon, profile) in scenarios {
            let fake = Fake::new(|script, _| {
                if script == "true" {
                    out("")
                } else if script.starts_with("printf 'bin=") {
                    out(version(bin))
                } else if script.starts_with("cat ~/.acpmux/config.json 2>/dev/null;") {
                    out(status(daemon))
                } else if script.starts_with("printf %s") {
                    out("/home/leo")
                } else if script.contains("id -u") {
                    out(format!("1000\n-rw------- 1 1000 1000 9 Oct 20 12:00 f\n\0{profile}"))
                } else {
                    panic!("unexpected script: {script}")
                }
            });
            let mut lines = Vec::new();
            let results = machine_steps(&fake, &plan(&["pi"]), &local, false, &mut |r| {
                lines.push(step_line(r))
            });
            assert_eq!(lines.len(), 4);
            assert!(results.iter().any(|r| r.state == StepState::Fail), "{results:?}");
            assert!(fake.pushes.borrow().is_empty());
            for (script, stdin) in fake.calls.borrow().iter() {
                assert!(!stdin, "{script}");
                for writes in
                    ["mv ", "cat >", "ln -s", "launchctl", "daemon start", "chmod", "mkdir", "rm "]
                {
                    assert!(!script.contains(writes), "{script}");
                }
            }
        }
    }

    #[test]
    fn enroll_copies_a_stale_profile_rewritten_and_owner_only() {
        let build = crate::hub::BUILD;
        let local = local_with("fix", "pi", "command = \"/Users/leo/bin/pi\"\n");
        let written: RefCell<Option<String>> = RefCell::default();
        let fake = Fake::new(|script, stdin| {
            if let Some(bytes) = stdin {
                *written.borrow_mut() = Some(String::from_utf8(bytes.to_vec()).unwrap());
                return out("");
            }
            if script == "true" {
                out("")
            } else if script.starts_with("printf 'bin=") {
                out(version(build))
            } else if script.starts_with("cat ~/.acpmux/config.json 2>/dev/null;") {
                out(status(build))
            } else if script.starts_with("printf %s") {
                out("/home/leo")
            } else if script.contains("id -u") {
                // Group-writable until the copy replaces it.
                match written.borrow().as_deref() {
                    Some(body) => {
                        out(format!("1000\n-rw------- 1 1000 1000 9 Oct 20 12:00 f\n\0{body}"))
                    }
                    None => out("1000\n-rw-rw-r-- 1 1000 1000 9 Oct 20 12:00 f\n\0old"),
                }
            } else {
                panic!("unexpected script: {script}")
            }
        });
        let results = machine_steps(&fake, &plan(&["pi"]), &local, true, &mut |_| {});
        assert_eq!(
            states(&results),
            [
                (Step::Reach, StepState::Ok),
                (Step::Install, StepState::Ok),
                (Step::Daemon, StepState::Ok),
                (Step::Harness, StepState::Fixed)
            ]
        );
        assert_eq!(written.borrow().as_deref(), Some("command = \"/home/leo/bin/pi\"\n"));
        let calls = fake.calls.borrow();
        let (write, _) = calls.iter().find(|(_, stdin)| *stdin).unwrap();
        assert!(write.contains("chmod 700 \"$d\"") && write.contains("chmod 600"), "{write}");
        assert!(!write.contains("/home/leo/bin/pi"), "the profile goes over stdin");
    }

    #[test]
    fn install_refuses_another_platform_and_reach_failure_skips_the_rest() {
        let fake = Fake::new(|script, _| {
            if script == "true" {
                out("")
            } else if script.starts_with("printf 'bin=") {
                out("bin=\n")
            } else if script == "uname -sm" {
                out("Plan9 mips")
            } else {
                panic!("unexpected script: {script}")
            }
        });
        let results = machine_steps(
            &fake,
            &plan(&[]),
            &Local { harness_dir: None, home: None },
            true,
            &mut |_| {},
        );
        assert_eq!(results[1].state, StepState::Fail);
        assert!(results[1].fix.as_deref().unwrap().contains("cmux remote install"));
        assert!(fake.pushes.borrow().is_empty());
        assert_eq!(results[2].detail, "needs install");

        let fake = Fake::new(|_, _| RemoteOut {
            ok: false,
            stdout: String::new(),
            stderr: "leo@box.tail: Permission denied (publickey).".into(),
        });
        let results = machine_steps(
            &fake,
            &plan(&["pi"]),
            &Local { harness_dir: None, home: None },
            true,
            &mut |_| {},
        );
        assert_eq!(results[0].state, StepState::Fail);
        assert!(results[0].detail.starts_with("the ssh key was rejected"));
        assert!(results[1..].iter().all(|r| r.state == StepState::Skip));
        assert_eq!(fake.calls.borrow().len(), 1);
    }

    /// Runs the scripts in a local `sh` with `HOME` at a temp folder, so the
    /// harness scripts meet a real shell, `ls` and file modes.
    #[cfg(unix)]
    struct Sh(PathBuf);

    #[cfg(unix)]
    impl Remote for Sh {
        fn host(&self) -> &str {
            "sh"
        }
        fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut> {
            let mut child = std::process::Command::new("sh")
                .args(["-c", script])
                .env("HOME", &self.0)
                .env_remove("XDG_CONFIG_HOME")
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .spawn()?;
            let mut pipe = child.stdin.take().unwrap();
            std::io::Write::write_all(&mut pipe, stdin.unwrap_or_default())?;
            drop(pipe);
            let out = child.wait_with_output()?;
            Ok(RemoteOut {
                ok: out.status.success(),
                stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
                stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
            })
        }
        fn push(&self, _local: &Path, _remote: &str) -> Result<()> {
            unreachable!()
        }
    }

    #[test]
    #[cfg(unix)]
    fn the_harness_scripts_copy_owner_only_and_catch_a_writable_profile() {
        use std::os::unix::fs::PermissionsExt;
        let local = local_with("sh", "pi", "command = \"/Users/leo/bin/pi\"\n");
        let home =
            std::env::temp_dir().join(format!("acpmux-enroll-sh-home-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let sh = Sh(home.clone());
        let ids = vec!["pi".to_string()];
        assert_eq!(harness(&sh, &ids, &local, false).state, StepState::Fail);
        let fixed = harness(&sh, &ids, &local, true);
        assert_eq!(fixed.state, StepState::Fixed, "{fixed:?}");
        assert_eq!(fixed.detail, "pi copied (missing)");
        let dir = home.join(".config/cmux/harnesses");
        let file = dir.join("pi.toml");
        let remote_home = home.to_string_lossy();
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            format!("command = \"{remote_home}/bin/pi\"\n")
        );
        assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(harness(&sh, &ids, &local, false).state, StepState::Ok);
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o664)).unwrap();
        let writable = harness(&sh, &ids, &local, false);
        assert_eq!(writable.state, StepState::Fail);
        assert!(writable.detail.contains("group- or other-writable"), "{writable:?}");
        assert_eq!(harness(&sh, &ids, &local, true).state, StepState::Fixed);
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        let _ = std::fs::remove_dir_all(&home);
    }
}
