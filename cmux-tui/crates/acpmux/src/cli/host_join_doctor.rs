//! `acpmux host doctor --here` (also `cmux machine doctor` with no machine):
//! whether this machine's one-line join works, step by step, each failure
//! with the exact command that fixes it.
//!
//! The steps are the Add Machine checklist's lines (`{"step","state",
//! "detail","fix"}`, then `{"report":…}`; `host_steps.rs`), so the app shows
//! them unchanged. What the join holds comes from `acpmux host join --status
//! --json` of the installed `~/.local/bin/acpmux`:
//! `{credentialPresent, machineId, teamId, hubOrigin, hubReachable,
//! lastHeartbeat, revoked, consent: {screen, control, grantedAt?}}`; a field
//! it does not report skips its step instead of failing it.
//!
//! `--fix` runs only local, idempotent repairs (enable the installed service,
//! start the daemon). It never mints or redeems a token.

// The probes are Unix only (joining is macOS and Linux); the steps build everywhere.
#![cfg_attr(not(unix), allow(dead_code, unused_imports))]

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use serde::Serialize;
use serde_json::{Value, json};

use super::host_steps::StepState;

/// The platform the join line comes from until joining is on elsewhere.
pub const DEV_ORIGIN: &str = "https://cmux-platform-development.debussy.workers.dev";
/// A heartbeat older than this means the machine has dropped off the mesh
/// (the hub's own limit, cmux#27079).
pub const HEARTBEAT_WITHIN_MS: u64 = 90_000;
const STATUS_TIMEOUT: Duration = Duration::from_secs(15);
const NEW_LINE: &str = "Make a new line on your Mac: cmux machine add, and paste it here";
const SERVICE: &str = "acpmux.service";
const LAUNCHD_LABEL: &str = "com.acpmux.daemon";

/// One checklist line.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct JoinStep {
    pub step: &'static str,
    pub state: StepState,
    pub detail: String,
    pub fix: Option<String>,
}

impl JoinStep {
    pub fn new(step: &'static str, state: StepState, detail: impl Into<String>) -> Self {
        Self { step, state, detail: detail.into(), fix: None }
    }

    pub fn fail(step: &'static str, detail: impl Into<String>, fix: impl Into<String>) -> Self {
        Self { step, state: StepState::Fail, detail: detail.into(), fix: Some(fix.into()) }
    }

    pub fn with_fix(mut self, fix: impl Into<String>) -> Self {
        self.fix = Some(fix.into());
        self
    }

    pub fn healthy(&self) -> bool {
        !matches!(self.state, StepState::Fail)
    }
}

/// The installed binary.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Binary {
    Ok(PathBuf),
    Missing(PathBuf),
    NotExecutable(PathBuf),
}

/// The service that keeps the daemon running.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Service {
    /// Running under systemd or launchd; `linger` is Linux's (None: unknown, or macOS).
    Active { linger: Option<bool> },
    /// Not running; `installed` when its unit or plist is on disk.
    Inactive { installed: bool },
    /// No systemd user session or launchctl here (a container).
    NoManager,
}

/// What `acpmux host join --status --json` said.
#[derive(Clone, Debug, PartialEq)]
pub enum Status {
    Json(Value),
    /// The installed acpmux predates joining (it refused `--status`).
    Unsupported,
    /// It failed another way; the words say how (never its output).
    Failed(String),
    /// Not asked: there is no binary to ask.
    NotRun,
}

/// Everything the steps read, gathered by [`probe`] (tests build it by hand).
#[derive(Clone, Debug, PartialEq)]
pub struct Facts {
    pub linux: bool,
    pub binary: Binary,
    pub service: Service,
    pub daemon_running: bool,
    /// The running daemon's capability ids (`acpmux daemon status --json`); `None` when it
    /// could not be read (no daemon, or it did not answer).
    pub capabilities: Option<Vec<String>>,
    pub status: Status,
}

/// The capability a daemon with the join consent gate serves.
pub const CONSENT_GATE: &str = "machine-consent-v1";

/// The join line's origin for fix text: the hub the status names, else development.
/// Only a bare `https://host[:port]` is printed: no user, path, query or fragment (a pasted
/// secret could hide in any of them).
fn origin(facts: &Facts) -> String {
    let bare = |o: &&str| {
        o.strip_prefix("https://").is_some_and(|rest| {
            let host = rest.strip_suffix('/').unwrap_or(rest);
            !host.is_empty()
                && host
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b':'))
        }) && plain(o)
    };
    match &facts.status {
        Status::Json(v) => v["hubOrigin"]
            .as_str()
            .filter(bare)
            .unwrap_or(DEV_ORIGIN)
            .trim_end_matches('/')
            .to_owned(),
        _ => DEV_ORIGIN.to_owned(),
    }
}

/// `text` as one shell word: as is when it is only `A-Za-z0-9/._-~+`, else single-quoted.
fn shell_word(text: &str) -> String {
    let bare = !text.is_empty()
        && text.bytes().all(|b| b.is_ascii_alphanumeric() || b"/._-~+".contains(&b));
    if bare { text.to_owned() } else { format!("'{}'", text.replace('\'', "'\\''")) }
}

/// Text from the status that is safe to print: no control characters and no join token or
/// machine credential.
fn plain(text: &str) -> bool {
    !text.chars().any(char::is_control) && !text.contains("cmj_") && !text.contains("cmm_")
}

fn rejoin(facts: &Facts) -> String {
    format!(
        "Re-run the join line without a token: curl -fsSL {}/v1/machines/join.sh | sh",
        origin(facts)
    )
}

/// The checklist for `facts` at `now_ms`.
pub fn steps(facts: &Facts, now_ms: u64) -> Vec<JoinStep> {
    let mut steps = vec![binary_step(facts), service_step(facts)];
    steps.push(if facts.daemon_running {
        JoinStep::new("daemon", StepState::Ok, "the acpmux daemon answers")
    } else {
        JoinStep::fail("daemon", "the acpmux daemon does not answer", "acpmux daemon start")
    });
    let status = match &facts.status {
        Status::Json(v) => Some(v),
        _ => None,
    };
    let credential = credential_step(facts);
    let joined = credential.state == StepState::Ok;
    steps.push(credential);
    let skip = |step: &'static str, why: &str| JoinStep::new(step, StepState::Skip, why);
    let Some(status) = status.filter(|_| joined) else {
        for step in ["revoked", "hub", "heartbeat"] {
            steps.push(skip(step, "this machine has not joined"));
        }
        steps.push(consent_step(facts, status));
        return steps;
    };
    let revoked = status["revoked"].as_bool() == Some(true);
    steps.push(match status["revoked"].as_bool() {
        Some(true) => JoinStep::fail("revoked", "your team revoked this machine", NEW_LINE),
        Some(false) => JoinStep::new("revoked", StepState::Ok, "not revoked"),
        None => skip("revoked", "acpmux did not say whether this machine is revoked"),
    });
    let hub = origin(facts);
    steps.push(match status["hubReachable"].as_bool() {
        Some(true) => JoinStep::new("hub", StepState::Ok, format!("reaches {hub}")),
        Some(false) => JoinStep::fail(
            "hub",
            format!("cannot reach {hub}"),
            format!("This machine cannot reach {hub} on 443: check its outbound HTTPS or proxy"),
        ),
        None => skip("hub", "acpmux did not say whether it reaches the hub"),
    });
    steps.push(if revoked {
        skip("heartbeat", "this machine is revoked")
    } else {
        match status.get("lastHeartbeat") {
            // A field this acpmux does not report; `null` is "none yet", a failure.
            None => skip("heartbeat", "acpmux did not report the last heartbeat"),
            Some(at) => heartbeat_step(at, now_ms),
        }
    });
    steps.push(consent_step(facts, Some(status)));
    steps
}

fn binary_step(facts: &Facts) -> JoinStep {
    match &facts.binary {
        Binary::Ok(path) => {
            JoinStep::new("binary", StepState::Ok, format!("acpmux at {}", path.display()))
        }
        Binary::Missing(path) => {
            JoinStep::fail("binary", format!("no acpmux at {}", path.display()), rejoin(facts))
        }
        Binary::NotExecutable(path) => {
            JoinStep::fail("binary", format!("{} is not executable", path.display()), rejoin(facts))
        }
    }
}

fn service_step(facts: &Facts) -> JoinStep {
    let (what, start) = if facts.linux {
        (SERVICE.to_owned(), format!("systemctl --user enable --now {SERVICE}"))
    } else {
        (
            format!("the {LAUNCHD_LABEL} LaunchAgent"),
            format!(
                "launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/{LAUNCHD_LABEL}.plist"
            ),
        )
    };
    match facts.service {
        Service::Active { linger: Some(false) } => JoinStep::new(
            "service",
            StepState::Warn,
            format!("{what} runs, but stops when you log out (linger is off)"),
        )
        .with_fix("loginctl enable-linger $USER"),
        Service::Active { .. } => JoinStep::new("service", StepState::Ok, format!("{what} runs")),
        Service::Inactive { installed: true } => {
            JoinStep::fail("service", format!("{what} is installed but not running"), start)
        }
        Service::Inactive { installed: false } => {
            JoinStep::fail("service", format!("{what} is not installed"), rejoin(facts))
        }
        Service::NoManager => JoinStep::new(
            "service",
            StepState::Warn,
            "no service manager here: the daemon runs only while something starts it",
        ),
    }
}

fn credential_step(facts: &Facts) -> JoinStep {
    match &facts.status {
        Status::Json(v) if v["credentialPresent"].as_bool() == Some(true) => {
            let mode = v["credentialMode"].as_str().map(|m| m.trim_start_matches('0'));
            let loose = mode.is_some_and(|mode| mode != "600");
            if loose {
                let shown = mode.filter(|m| m.len() <= 4 && m.bytes().all(|b| b.is_ascii_digit()));
                let fix = match v["credentialPath"].as_str().filter(|p| plain(p)) {
                    Some(path) => format!("chmod 600 {}", shell_word(path)),
                    None => "chmod 600 the file acpmux host join --status --json names as credentialPath"
                        .to_owned(),
                };
                return JoinStep::fail(
                    "credential",
                    format!(
                        "the credential file is mode {}, readable by others",
                        shown.unwrap_or("not 600")
                    ),
                    fix,
                );
            }
            let id = v["machineId"].as_str().filter(|id| plain(id) && id.len() <= 128);
            JoinStep::new(
                "credential",
                StepState::Ok,
                format!("joined as {}", id.unwrap_or("this machine")),
            )
        }
        Status::Json(v) if v.get("credentialPresent").is_none() => JoinStep::new(
            "credential",
            StepState::Skip,
            "acpmux did not say whether this machine joined",
        ),
        Status::Json(_) => {
            JoinStep::fail("credential", "this machine has not joined a team", NEW_LINE)
        }
        Status::Unsupported => JoinStep::fail(
            "credential",
            "this acpmux cannot join yet (it has no host join --status)",
            rejoin(facts),
        ),
        Status::Failed(why) => JoinStep::fail(
            "credential",
            format!("acpmux host join --status failed ({why})"),
            rejoin(facts),
        ),
        Status::NotRun => JoinStep::new("credential", StepState::Skip, "no acpmux to ask"),
    }
}

fn heartbeat_step(value: &Value, now_ms: u64) -> JoinStep {
    let fix = "acpmux daemon restart; if it persists, acpmux config must name meshRelay";
    let Some(at) = epoch_ms(value) else {
        return JoinStep::fail("heartbeat", "no heartbeat reached the hub yet", fix);
    };
    let age = now_ms.saturating_sub(at);
    if age < HEARTBEAT_WITHIN_MS {
        JoinStep::new("heartbeat", StepState::Ok, format!("last heartbeat {}s ago", age / 1000))
    } else {
        JoinStep::fail("heartbeat", format!("last heartbeat {} ago", age_words(age)), fix)
    }
}

/// Informational: never fails.
fn consent_step(facts: &Facts, status: Option<&Value>) -> JoinStep {
    // A running daemon without the gate serves screen and control to the team ungated.
    if facts.daemon_running
        && facts.capabilities.as_ref().is_some_and(|ids| !ids.iter().any(|id| id == CONSENT_GATE))
    {
        return JoinStep::fail(
            "consent",
            format!("this acpmux daemon has no consent gate ({CONSENT_GATE})"),
            format!("Update acpmux. {}", rejoin(facts)),
        );
    }
    // `consent` is the record, or the daemon's `{consent, lastRefusal}` view of it.
    let view = status.map(|s| &s["consent"]);
    let nested = view.map(|v| &v["consent"]).filter(|c| c.is_object());
    let Some(consent) = nested.or(view.filter(|c| c.is_object())) else {
        return JoinStep::new("consent", StepState::Skip, "acpmux did not report consent");
    };
    let on = |key: &str| matches!(&consent[key], Value::Bool(true)) || consent[key] == "granted";
    let word = |key: &str| if on(key) { "on" } else { "off" };
    let mut detail = format!("screen sharing {}, control {}", word("screen"), word("control"));
    let refusal = [view.map(|v| &v["lastRefusal"]), status.map(|s| &s["lastRefusal"])]
        .into_iter()
        .flatten()
        .find(|r| r.is_object());
    if let Some(surface) =
        refusal.and_then(|r| r["surface"].as_str()).filter(|s| matches!(*s, "screen" | "control"))
    {
        detail.push_str(&format!("; a {surface} request was last refused here"));
    }
    if !on("screen") || !on("control") {
        detail.push_str("; to allow, run here: acpmux host consent grant --screen (or --control)");
    }
    JoinStep::new("consent", StepState::Ok, detail)
}

/// "3 min", "2 h", "4 days".
pub fn age_words(ms: u64) -> String {
    let minutes = ms / 60_000;
    match minutes {
        0..=1 => format!("{}s", ms / 1000),
        2..=119 => format!("{minutes} min"),
        120..=2879 => format!("{} h", minutes / 60),
        _ => format!("{} days", minutes / 1440),
    }
}

/// Milliseconds since the epoch from RFC 3339 text, epoch milliseconds, or epoch seconds.
pub fn epoch_ms(value: &Value) -> Option<u64> {
    match value {
        Value::Number(n) => {
            let n = n.as_u64()?;
            Some(if n < 100_000_000_000 { n.saturating_mul(1000) } else { n })
        }
        Value::String(text) => {
            cmux_chat_index::time::parse_rfc3339_ms(text).and_then(|ms| u64::try_from(ms).ok())
        }
        _ => None,
    }
}

/// How the checklist prints.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Print {
    /// Aligned lines for a person.
    Human,
    /// One JSON line per step, then `{"report":…}`.
    Lines,
    /// Nothing; the exit code says it.
    Quiet,
}

/// The checklist as text, and whether every step is healthy.
pub fn render(name: &str, host: &str, steps: &[JoinStep], print: Print) -> (String, bool) {
    let ok = steps.iter().all(JoinStep::healthy);
    let mut text = String::new();
    match print {
        Print::Quiet => {}
        Print::Lines => {
            for step in steps {
                text.push_str(&serde_json::to_string(step).unwrap_or_default());
                text.push('\n');
            }
            let report = json!({"report": {"name": name, "host": host, "ok": ok, "steps": steps}});
            text.push_str(&report.to_string());
            text.push('\n');
        }
        Print::Human => {
            for step in steps {
                let state = serde_json::to_value(step.state)
                    .ok()
                    .and_then(|v| v.as_str().map(str::to_owned))
                    .unwrap_or_default();
                text.push_str(&format!("{state:<6} {:<10} {}\n", step.step, step.detail));
                if let Some(fix) = &step.fix {
                    text.push_str(&format!("{:<17} fix: {fix}\n", ""));
                }
            }
            let verdict = if ok { "healthy" } else { "needs attention" };
            text.push_str(&format!("{name} ({host}): {verdict}\n"));
        }
    }
    (text, ok)
}

/// The installed binary's path: `~/.local/bin/acpmux`.
fn installed(home: &Path) -> PathBuf {
    home.join(".local/bin/acpmux")
}

/// Reads this machine.
#[cfg(unix)]
pub fn probe() -> Facts {
    use std::os::unix::fs::PermissionsExt as _;
    let home = dirs::home_dir().unwrap_or_default();
    let path = installed(&home);
    let binary = match std::fs::metadata(&path) {
        Ok(meta) if meta.is_file() && meta.permissions().mode() & 0o111 != 0 => {
            Binary::Ok(path.clone())
        }
        Ok(_) => Binary::NotExecutable(path.clone()),
        Err(_) => Binary::Missing(path.clone()),
    };
    let linux = cfg!(target_os = "linux");
    let service = if linux { systemd_service(&home) } else { launchd_service(&home) };
    let daemon_running =
        std::os::unix::net::UnixStream::connect(crate::config::socket_path()).is_ok();
    let (status, capabilities) = match &binary {
        Binary::Ok(path) => {
            (join_status(path), daemon_running.then(|| daemon_capabilities(path)).flatten())
        }
        _ => (Status::NotRun, None),
    };
    Facts { linux, binary, service, daemon_running, capabilities, status }
}

/// `command args…` run with no stdin and a deadline: its exit code and stdout.
#[cfg(unix)]
fn output(program: &Path, args: &[&str]) -> Option<(i32, String)> {
    use std::io::Read as _;
    use wait_timeout::ChildExt as _;
    let mut child = Command::new(program)
        .args(args)
        // The caller's cmux credential and any join token stay out of the children.
        .env_remove("CMUX_CLOUD_ACCESS_TOKEN")
        .env_remove("CMUX_JOIN")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = stdout.read_to_string(&mut text);
        text
    });
    let status = match child.wait_timeout(STATUS_TIMEOUT).ok()? {
        Some(status) => status,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
    };
    let text = reader.join().unwrap_or_default();
    Some((status.code().unwrap_or(-1), text))
}

/// The capability ids the running daemon reports in its status; an answer without the
/// list is a daemon that predates capabilities (none).
#[cfg(unix)]
fn daemon_capabilities(binary: &Path) -> Option<Vec<String>> {
    let (code, text) = output(binary, &["daemon", "status", "--json"])?;
    let v: Value = serde_json::from_str(text.trim()).ok().filter(|_| code == 0)?;
    v.is_object().then(|| capability_ids(&v))
}

/// `status.capabilities` as ids; absent or malformed is none.
pub fn capability_ids(status: &Value) -> Vec<String> {
    status["capabilities"]
        .as_array()
        .map(|ids| ids.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

#[cfg(unix)]
fn join_status(binary: &Path) -> Status {
    match output(binary, &["host", "join", "--status", "--json"]) {
        None => Status::Failed("it did not answer in time".into()),
        Some((0, text)) => match serde_json::from_str::<Value>(text.trim()) {
            Ok(v) if v.is_object() => Status::Json(v),
            _ => Status::Failed("it printed no status".into()),
        },
        // clap's usage error: this build has no `--status`.
        Some((2, _)) => Status::Unsupported,
        Some((code, _)) => Status::Failed(format!("exit {code}")),
    }
}

#[cfg(unix)]
fn systemd_service(home: &Path) -> Service {
    let Some((_, state)) = output(Path::new("systemctl"), &["--user", "is-active", SERVICE]) else {
        return Service::NoManager;
    };
    if state.trim() == "active" {
        let user = std::env::var("USER").unwrap_or_default();
        let linger =
            output(Path::new("loginctl"), &["show-user", &user, "--property=Linger", "--value"])
                .map(|(_, v)| v.trim() == "yes");
        return Service::Active { linger };
    }
    let installed = home.join(".config/systemd/user").join(SERVICE).is_file();
    Service::Inactive { installed }
}

#[cfg(unix)]
fn launchd_service(home: &Path) -> Service {
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let job = format!("gui/{uid}/{LAUNCHD_LABEL}");
    match output(Path::new("launchctl"), &["print", &job]) {
        None => Service::NoManager,
        Some((0, _)) => Service::Active { linger: None },
        Some(_) => {
            let plist = home.join("Library/LaunchAgents").join(format!("{LAUNCHD_LABEL}.plist"));
            Service::Inactive { installed: plist.is_file() }
        }
    }
}

/// The local repairs for `facts`: reinstall a missing binary (the join script, no token),
/// start the installed service, turn linger on, then start the daemon. True when one ran.
#[cfg(unix)]
fn repair(facts: &Facts) -> bool {
    let mut ran = false;
    // A missing binary or service: the one install path, the join script with no token,
    // which installs and repairs only (checked download, service, daemon) and never redeems.
    // Then the rest below runs on what it left.
    let reinstalled;
    let facts = if !matches!(facts.binary, Binary::Ok(_))
        || facts.service == (Service::Inactive { installed: false })
    {
        ran = true;
        let script = format!(
            "curl --proto '=https' --tlsv1.2 -fsSL {}/v1/machines/join.sh | sh",
            origin(facts)
        );
        let _ = output(Path::new("sh"), &["-c", &script]);
        reinstalled = probe();
        &reinstalled
    } else {
        facts
    };
    if facts.service == (Service::Inactive { installed: true }) {
        ran = true;
        if facts.linux {
            let _ = output(Path::new("systemctl"), &["--user", "enable", "--now", SERVICE]);
        } else {
            // SAFETY: getuid has no preconditions.
            let uid = unsafe { libc::getuid() };
            let home = dirs::home_dir().unwrap_or_default();
            let plist = home.join("Library/LaunchAgents").join(format!("{LAUNCHD_LABEL}.plist"));
            let plist = plist.display().to_string();
            let _ = output(Path::new("launchctl"), &["bootstrap", &format!("gui/{uid}"), &plist]);
        }
    }
    if facts.service == (Service::Active { linger: Some(false) }) {
        ran = true;
        let user = std::env::var("USER").unwrap_or_default();
        if !user.is_empty() {
            let _ = output(Path::new("loginctl"), &["enable-linger", &user]);
        }
    }
    if !facts.daemon_running
        && let Binary::Ok(binary) = &facts.binary
    {
        ran = true;
        let _ = output(binary, &["daemon", "start"]);
    }
    ran
}

/// `before`'s failures that `after` no longer has, marked fixed.
pub fn mark_fixed(before: &[JoinStep], mut after: Vec<JoinStep>) -> Vec<JoinStep> {
    for step in &mut after {
        let failed = before.iter().any(|b| b.step == step.step && b.state == StepState::Fail);
        if failed && step.state == StepState::Ok {
            step.state = StepState::Fixed;
        }
    }
    after
}

/// Runs the checklist here; with `fix`, the local repairs first. The exit
/// code is 0 when every step is healthy, else 1.
#[cfg(unix)]
pub fn run_here(fix: bool, print: Print, out: &mut dyn std::io::Write) -> i32 {
    let now = || {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
            .unwrap_or_default()
    };
    let facts = probe();
    let mut checked = steps(&facts, now());
    if fix && repair(&facts) {
        checked = mark_fixed(&checked, steps(&probe(), now()));
    }
    let name = crate::cli::hosts::short_name(&crate::hand::pair::hostname());
    let (text, ok) = render(&name, "this machine", &checked, print);
    let _ = out.write_all(text.as_bytes());
    let _ = out.flush();
    i32::from(!ok)
}

/// Joining is macOS and Linux only.
#[cfg(not(unix))]
pub fn run_here(_fix: bool, print: Print, out: &mut dyn std::io::Write) -> i32 {
    let step = JoinStep::new("binary", StepState::Fail, "joining needs macOS or Linux");
    let (text, _) = render("this machine", "this machine", &[step], print);
    let _ = out.write_all(text.as_bytes());
    1
}

#[cfg(test)]
#[path = "host_join_doctor_tests.rs"]
mod tests;
