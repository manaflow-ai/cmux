//! "Launch this app" on a machine: `_acpmux/app_launch` and `_acpmux/app_list`, answered by the
//! daemon of the machine the app opens on (`server/app_launch.rs`), reached over the same peer
//! link `acpmux new --machine` starts a chat over (ssh, direct, WireGuard or the hub carrier).
//! Leo, 2026-11-16: "it's not like i can just easily say "launch this app" from my comuputer
//! (maybe that should be a feature)" (hq docs/design/remote-screen-share-zero-touch.md, Z6).
//!
//! An app is named by its name (`Safari`, `cmux`), its id (a bundle id on macOS, a desktop
//! entry id on Linux) or an absolute path. It opens in the logged-in GUI session: on macOS
//! through LaunchServices (`/usr/bin/open`, put in the person's GUI session with
//! `launchctl asuser` when the daemon runs outside it, `daemon/login_session.rs`); on Linux from
//! its desktop entry's `Exec`, in the session whose display the user's systemd manager knows.
//! Arguments are an argument vector from end to end: no shell ever reads them. Without
//! `activate` the app opens behind the window in front and takes no focus.
//!
//! Every blocking step here has a deadline; the caller runs it off the async runtime.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;

mod desktop_entry;
mod resolve;

pub use resolve::resolve;

/// The longest a launch waits for its app's process to show, unless the caller asks less.
// timeout: an app that has not shown in 15 s is reported, with --wait up to MAX_WAIT.
pub const DEFAULT_WAIT: Duration = Duration::from_secs(15);
/// The longest any caller may ask a launch to wait.
pub const MAX_WAIT: Duration = Duration::from_secs(60);
/// The most arguments one launch passes.
const MAX_ARGS: usize = 256;
/// The most apps a list reads, so a folder full of bundles never makes a read unbounded.
pub(crate) const MAX_APPS: usize = 4000;

/// One app this machine can open.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct App {
    /// What a person calls it: the bundle's display name, the desktop entry's `Name`.
    pub name: String,
    /// Its id: the bundle id (macOS), the desktop entry id (Linux). None when it has none.
    pub id: Option<String>,
    /// The bundle (macOS), the desktop entry file or an executable (Linux).
    pub path: PathBuf,
    /// The program a running copy runs from, when it can be told from here: the bundle's
    /// `Contents/MacOS/` folder, or the desktop entry's `Exec` program.
    pub exe: Option<PathBuf>,
}

impl App {
    fn json(&self) -> Value {
        json!({"name": self.name, "id": self.id, "path": self.path.to_string_lossy()})
    }
}

/// One running process of an app.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Running {
    pub pid: u32,
    pub exe: PathBuf,
}

/// A launch, as the caller asked for it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LaunchRequest {
    pub app: String,
    pub args: Vec<String>,
    /// Bring it to the front (default: open behind, no focus taken).
    pub activate: bool,
    /// Open it hidden (macOS `open -j`), as device setup opens cmux.
    pub hidden: bool,
    /// Open another copy even when one runs (macOS `open -n`); arguments reach only a new copy.
    pub new_instance: bool,
    /// How long to wait for its process to show.
    pub wait: Duration,
}

impl LaunchRequest {
    /// A request from `_acpmux/app_launch`'s params: `{app, args?, activate?, hidden?, new?,
    /// waitMs?}`.
    pub fn from_params(params: &Value) -> Result<Self, Refusal> {
        let app = params.get("app").and_then(Value::as_str).unwrap_or_default().to_owned();
        let args = match params.get("args") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(items)) => items
                .iter()
                .map(|a| a.as_str().map(str::to_owned))
                .collect::<Option<Vec<_>>>()
                .ok_or_else(|| Refusal::Invalid("args must be a list of strings".into()))?,
            Some(_) => return Err(Refusal::Invalid("args must be a list of strings".into())),
        };
        let flag = |key: &str| params.get(key).and_then(Value::as_bool).unwrap_or(false);
        let wait = params
            .get("waitMs")
            .and_then(Value::as_u64)
            .map_or(DEFAULT_WAIT, Duration::from_millis)
            .min(MAX_WAIT);
        let request = Self {
            app,
            args,
            activate: flag("activate"),
            hidden: flag("hidden"),
            new_instance: flag("new"),
            wait,
        };
        request.check()?;
        Ok(request)
    }

    /// What a launch refuses before it looks for the app: an empty or flag-like name, a
    /// relative path, a control character, too many or too large arguments. An argument may hold
    /// anything but NUL: it is passed as one element of the argument vector.
    fn check(&self) -> Result<(), Refusal> {
        let app = self.app.trim();
        if app.is_empty() {
            return Err(Refusal::Invalid("name the app: a name, an id or an absolute path".into()));
        }
        // `open` and a launcher read a leading `-` as their own option.
        if app.starts_with('-') {
            return Err(Refusal::Invalid(format!("{app:?} is not an app name")));
        }
        if app.chars().any(char::is_control) {
            return Err(Refusal::Invalid("the app name holds a control character".into()));
        }
        if app.contains('/') && !Path::new(app).is_absolute() {
            return Err(Refusal::Invalid(format!("{app:?}: a path must be absolute")));
        }
        if self.args.len() > MAX_ARGS {
            return Err(Refusal::Invalid(format!("more than {MAX_ARGS} arguments")));
        }
        if self.args.iter().any(|a| a.contains('\0')) {
            return Err(Refusal::Invalid("an argument holds a NUL byte".into()));
        }
        Ok(())
    }
}

/// Why an app did not open, with what to run next. Each is one `reason` code on the wire.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// Nobody is logged in at the screen (the login window, or no desktop session).
    NoSession(String),
    /// Someone else than the daemon's user is at the screen.
    OtherUser(String),
    /// No app by that name, id or path.
    NotFound(String),
    /// The request itself is wrong (`check`).
    Invalid(String),
    /// This platform has no launcher yet.
    Unsupported,
    /// The launcher ran and failed, or its app never showed.
    Failed(String),
}

impl Refusal {
    pub fn reason(&self) -> &'static str {
        match self {
            Self::NoSession(_) | Self::OtherUser(_) => "app.no_session",
            Self::NotFound(_) => "app.not_found",
            Self::Invalid(_) => "app.invalid",
            Self::Unsupported => "app.unsupported",
            Self::Failed(_) => "app.launch_failed",
        }
    }

    /// The sentence, on `machine`.
    pub fn message(&self, machine: &str) -> String {
        match self {
            Self::NoSession(why) => format!("nobody is logged in on {machine}: {why}"),
            Self::OtherUser(who) => {
                format!("{who} is logged in at {machine}'s screen, not this daemon's user")
            }
            Self::NotFound(app) => format!("no app named {app:?} on {machine}"),
            Self::Invalid(why) => why.clone(),
            Self::Unsupported => format!("app launch is not supported on {machine}'s system yet"),
            Self::Failed(why) => format!("the app did not open on {machine}: {why}"),
        }
    }

    /// What to run next, as one line, for a launch of `app` on `machine` (`on` is the CLI's
    /// `--on MACHINE` words, empty for this machine).
    pub fn next(&self, app: &str, on: &str) -> String {
        match self {
            Self::NoSession(_) => {
                "log in at the screen (fleet Macs: turn on automatic login), then run it again"
                    .into()
            }
            Self::OtherUser(_) => "run it as the user who is logged in at the screen".into(),
            Self::NotFound(_) => format!("`cmux app list{on}` lists the apps there"),
            Self::Invalid(_) => format!("`cmux app launch{on} APP [-- ARGS]`"),
            Self::Unsupported => "open it there by hand, or use a macOS or Linux machine".into(),
            Self::Failed(_) => format!("`cmux app list{on}` shows whether {app} runs there"),
        }
    }
}

/// A launch that went through: the app and the process it runs as (or already ran as).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Launched {
    pub app: App,
    pub pid: Option<u32>,
    pub already_running: bool,
    pub ms: u64,
}

impl Launched {
    pub fn json(&self) -> Value {
        json!({
            "launched": true,
            "app": self.app.json(),
            "pid": self.pid,
            "alreadyRunning": self.already_running,
            "ms": self.ms,
        })
    }
}

/// Opens the app `request` names in the logged-in session and waits (at most `request.wait`)
/// for its process. Blocking.
pub fn launch(request: &LaunchRequest) -> Result<Launched, Refusal> {
    request.check()?;
    let started = Instant::now();
    let deadline = started + request.wait;
    let platform = Platform::here()?;
    platform.session()?;
    let apps = platform.apps();
    let app = resolve(&request.app, &apps, own_bundle().as_deref())?;
    let before = platform.running();
    let running_before: Vec<u32> = matching(&app, &before).map(|r| r.pid).collect();
    let spawned = platform.open(&app, request, deadline)?;
    let pid = match spawned {
        // The launcher is its process (Linux): its pid at once.
        Some(pid) => Some(pid),
        // A Linux launcher that handed it to a copy already running and exited: opened, and no
        // registry here knows that copy.
        None if !platform.asks_a_registry() => running_before.first().copied(),
        // LaunchServices opened it: its pid from LaunchServices' own list, a new one, else the
        // one that ran before (`open` hands the arguments to a running copy, or brings it forward).
        None => loop {
            let now = platform.running();
            let new = matching(&app, &now).map(|r| r.pid).find(|pid| !running_before.contains(pid));
            if let Some(pid) = new {
                break Some(pid);
            }
            if !running_before.is_empty() && !request.new_instance {
                break running_before.first().copied();
            }
            if Instant::now() >= deadline {
                return Err(Refusal::Failed(format!(
                    "{} did not show as running within {} ms",
                    app.name,
                    request.wait.as_millis()
                )));
            }
            // timeout: a poll interval inside the request's deadline, not a deadline.
            std::thread::sleep(Duration::from_millis(150));
        },
    };
    Ok(Launched {
        app,
        pid,
        already_running: spawned.is_none() && !running_before.is_empty() && !request.new_instance,
        ms: u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
    })
}

/// What this machine can open and what of it runs: `{platform, session, apps: [{name, id,
/// path, running, pids}]}`, apps that run first. Blocking.
pub fn list() -> Value {
    let Ok(platform) = Platform::here() else {
        return json!({"platform": std::env::consts::OS, "supported": false, "apps": []});
    };
    let session = match platform.session() {
        Ok(()) => json!({"loggedIn": true}),
        Err(refusal) => json!({"loggedIn": false, "why": refusal.message("this machine")}),
    };
    let running = platform.running();
    let mut apps: Vec<Value> = platform
        .apps()
        .iter()
        .map(|app| {
            let pids: Vec<u32> = matching(app, &running).map(|r| r.pid).collect();
            let mut row = app.json();
            row.set("running", json!(!pids.is_empty()));
            row.set("pids", json!(pids));
            row
        })
        .collect();
    apps.sort_by_key(|row| !row["running"].as_bool().unwrap_or(false));
    json!({"platform": std::env::consts::OS, "supported": true, "session": session, "apps": apps})
}

/// macOS `open`'s argument vector for `app` (`app_launch/macos.rs`): behind the front window
/// unless `activate`, hidden with `hidden`, a new copy with `new_instance`; the arguments after
/// `--args`, each one element. Here, not there, so its tests run on every platform.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn mac_open_argv(app: &App, request: &LaunchRequest) -> Vec<String> {
    let mut argv = vec!["/usr/bin/open".to_owned()];
    if !request.activate {
        argv.push("-g".into());
    }
    if request.hidden {
        argv.push("-j".into());
    }
    if request.new_instance {
        argv.push("-n".into());
    }
    argv.push("-a".into());
    argv.push(app.path.to_string_lossy().into_owned());
    if !request.args.is_empty() {
        argv.push("--args".into());
        argv.extend(request.args.iter().cloned());
    }
    argv
}

/// The apps `lsappinfo list` names (macOS, `app_launch/macos.rs`): each one's pid and executable.
/// An entry starts at a line like ` 12) "Safari" ASN:...`; its `executable path="..."` and
/// `pid = N` lines follow. An entry without both is left out. Here, not there, so its tests run
/// on every platform.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn lsappinfo_running(out: &str) -> Vec<Running> {
    let mut running = Vec::new();
    let (mut pid, mut exe): (Option<u32>, Option<PathBuf>) = (None, None);
    let mut flush = |pid: &mut Option<u32>, exe: &mut Option<PathBuf>| {
        if let (Some(pid), Some(exe)) = (pid.take(), exe.take()) {
            running.push(Running { pid, exe });
        }
    };
    for line in out.lines() {
        let line = line.trim();
        let starts_entry = line
            .split_once(") \"")
            .is_some_and(|(n, _)| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()));
        if starts_entry {
            flush(&mut pid, &mut exe);
        } else if let Some(rest) = line.strip_prefix("executable path=\"") {
            exe = rest.strip_suffix('"').map(PathBuf::from);
        } else if let Some(rest) = line.strip_prefix("bundle path=\"")
            && exe.is_none()
        {
            // An entry that names only its bundle: a program inside it stands for it.
            exe = rest.strip_suffix('"').map(|b| Path::new(b).join("Contents/MacOS/app"));
        } else if let Some(rest) = line.strip_prefix("pid = ") {
            pid = rest.split_whitespace().next().and_then(|n| n.parse().ok());
        }
    }
    flush(&mut pid, &mut exe);
    running
}

/// The processes of `running` that run `app`'s program.
fn matching<'a>(app: &'a App, running: &'a [Running]) -> impl Iterator<Item = &'a Running> {
    let program = app.exe.as_deref().unwrap_or(&app.path);
    running.iter().filter(move |r| runs_from(&r.exe, program))
}

/// Whether a process running `exe` is the app whose program is `program`: the same file, or
/// (a bundle's `Contents/MacOS` folder) a file in it.
fn runs_from(exe: &Path, program: &Path) -> bool {
    exe == program || (program.ends_with("Contents/MacOS") && exe.parent() == Some(program))
}

/// The cmux app this daemon came from, when it runs from inside one (`cmux` names it first).
fn own_bundle() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    exe.ancestors().find(|p| p.extension().is_some_and(|e| e == "app")).map(Path::to_path_buf)
}

/// This machine's launcher.
enum Platform {
    #[cfg(target_os = "macos")]
    Mac,
    #[cfg(target_os = "linux")]
    Linux(linux::Session),
    /// No launcher on this system (Windows answers `app.unsupported`); never made.
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    Other(std::convert::Infallible),
}

impl Platform {
    fn here() -> Result<Self, Refusal> {
        #[cfg(target_os = "macos")]
        return Ok(Self::Mac);
        #[cfg(target_os = "linux")]
        return Ok(Self::Linux(linux::Session::find()));
        #[allow(unreachable_code)]
        Err(Refusal::Unsupported)
    }

    fn session(&self) -> Result<(), Refusal> {
        match self {
            #[cfg(target_os = "macos")]
            Self::Mac => macos::session(),
            #[cfg(target_os = "linux")]
            Self::Linux(session) => session.check(),
            #[cfg(not(any(target_os = "macos", target_os = "linux")))]
            Self::Other(never) => match *never {},
        }
    }

    fn apps(&self) -> Vec<App> {
        match self {
            #[cfg(target_os = "macos")]
            Self::Mac => macos::apps(),
            #[cfg(target_os = "linux")]
            Self::Linux(_) => linux::apps(),
            #[cfg(not(any(target_os = "macos", target_os = "linux")))]
            Self::Other(never) => match *never {},
        }
    }

    /// Whether what runs comes from the system's own registry of apps (LaunchServices), which
    /// learns of a copy it opened a moment after `open` answers, so a launch waits for it there.
    fn asks_a_registry(&self) -> bool {
        match self {
            #[cfg(target_os = "macos")]
            Self::Mac => true,
            #[cfg(target_os = "linux")]
            Self::Linux(_) => false,
            #[cfg(not(any(target_os = "macos", target_os = "linux")))]
            Self::Other(never) => match *never {},
        }
    }

    fn running(&self) -> Vec<Running> {
        match self {
            #[cfg(target_os = "macos")]
            Self::Mac => macos::running(),
            #[cfg(target_os = "linux")]
            Self::Linux(_) => linux::running(),
            #[cfg(not(any(target_os = "macos", target_os = "linux")))]
            Self::Other(never) => match *never {},
        }
    }

    fn open(
        &self,
        app: &App,
        request: &LaunchRequest,
        deadline: Instant,
    ) -> Result<Option<u32>, Refusal> {
        match self {
            #[cfg(target_os = "macos")]
            Self::Mac => macos::open(app, request, deadline),
            #[cfg(target_os = "linux")]
            Self::Linux(session) => session.open(app, request, deadline),
            #[cfg(not(any(target_os = "macos", target_os = "linux")))]
            Self::Other(never) => {
                let _ = (app, request, deadline);
                match *never {}
            }
        }
    }
}

/// Runs `argv` (no shell) with stdin, stdout and stderr closed, and waits for it until
/// `deadline`; past it the child is ended (dropping a `cmux_process::Child` ends it). Its exit
/// status, or why it did not run.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn run_bounded(
    argv: &[String],
    env: &[(String, String)],
    deadline: Instant,
) -> Result<std::process::ExitStatus, String> {
    let (program, args) = argv.split_first().ok_or("nothing to run")?;
    let mut child = cmux_process::Command::new(program)
        .args(args)
        .envs(env.iter().map(|(k, v)| (k, v)))
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .spawn()
        .map_err(|e| format!("{program}: {e}"))?;
    let left = deadline.saturating_duration_since(Instant::now());
    match child.wait_timeout(left).map_err(|e| e.to_string())? {
        Some(status) => Ok(status),
        None => Err(format!("{program} did not finish in time")),
    }
}

/// The most bytes of a command's output a read keeps.
const MAX_OUTPUT: u64 = 8 * 1024 * 1024;

/// Runs `argv` (no shell) and returns its stdout, ended past `budget`. None when it could not
/// run, failed or timed out. Its stdout goes to an unlinked temporary file, so a large output
/// never blocks it on a full pipe and nothing has to drain one while it runs.
#[cfg_attr(not(any(target_os = "macos", target_os = "linux")), allow(dead_code))]
fn output_bounded(argv: &[&str], budget: Duration) -> Option<String> {
    use std::io::{Read as _, Seek as _};
    let (program, args) = argv.split_first()?;
    let path = std::env::temp_dir().join(format!(
        "acpmux-app-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).ok()?.as_nanos()
    ));
    let mut file =
        std::fs::OpenOptions::new().read(true).write(true).create_new(true).open(&path).ok()?;
    let _ = std::fs::remove_file(&path);
    let mut child = cmux_process::Command::new(program)
        .args(args)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::from(file.try_clone().ok()?))
        .stderr(cmux_process::Stdio::null())
        .spawn()
        .ok()?;
    let status = child.wait_timeout(budget).ok()??;
    if !status.success() {
        return None;
    }
    file.rewind().ok()?;
    let mut out = String::new();
    file.take(MAX_OUTPUT).read_to_string(&mut out).ok()?;
    Some(out)
}

#[cfg(test)]
#[path = "app_launch_tests.rs"]
mod tests;
