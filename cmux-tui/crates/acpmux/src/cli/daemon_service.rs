//! `acpmux daemon service install|uninstall|status`: the service that keeps this machine's own
//! daemon running across logouts and reboots. It writes the same files `host setup` writes on a
//! machine it reaches over ssh (`hosts.rs`): the LaunchAgent `com.acpmux.daemon` on macOS
//! ([`hosts::PLIST`]), the user systemd unit `acpmux.service` on Linux
//! ([`hosts::SYSTEMD_UNIT`]). The one-line machine join (`cmux-tui/scripts/machine-join.sh`)
//! runs `install` before it starts the daemon.
//!
//! `install` is idempotent: a file that already holds this build's text is not rewritten, and a
//! service that already runs from it is left running. On macOS the plist is always written; it
//! is loaded only where launchd has a GUI domain for this user (someone is logged in at the
//! screen), through `host setup`'s own reload script ([`hosts::launchd_reload`]), which moves a
//! daemon that runs outside the job under it. With no one logged in at the screen there is no
//! domain to load it into: the running daemon is left as it is and the agent loads at the next
//! login there, which is not a failure. On Linux a unit someone else wrote or edited is left as
//! it is (only one an earlier acpmux wrote is replaced, as `host update` does); the unit is
//! enabled and started, after a daemon that runs outside it is shut down keeping its agents.

use crate::cli::hosts;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The launchd label and systemd unit `host setup` uses too.
pub(crate) const LAUNCHD_LABEL: &str = "com.acpmux.daemon";
pub(crate) const SYSTEMD_SERVICE: &str = "acpmux.service";

/// What `daemon service` does.
#[derive(clap::Subcommand, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceAction {
    /// Install (or refresh) the LaunchAgent or user systemd unit and start the daemon under it.
    Install,
    /// Stop the service's daemon (hosted agents keep running) and remove the service.
    Uninstall,
    /// Whether the service is installed and running.
    Status,
}

/// How long one launchctl, systemctl or acpmux call may take; `host setup`'s reload script waits
/// up to 30 s for an old daemon to exit, so it gets more.
const CALL_WAIT: Duration = Duration::from_secs(20);
const RELOAD_WAIT: Duration = Duration::from_secs(90);

/// The machine `daemon service` acts on; tests fake it.
pub(crate) trait Machine {
    fn home(&self) -> PathBuf;
    fn linux(&self) -> bool;
    /// `program args…` with no stdin: its exit code, stdout and stderr; None when it could not
    /// run or did not finish within `wait`.
    fn run(&self, program: &str, args: &[&str], wait: Duration) -> Option<(i32, String, String)>;
    /// Whether this home's daemon answers on its socket.
    fn daemon_running(&self) -> bool;
}

/// Where the service stands after an `install`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum State {
    /// Loaded (launchd) or active (systemd): the daemon runs under it.
    Running,
    /// macOS with no one logged in at the screen: installed, loads at the next login there.
    AtNextLogin,
    /// Linux with no systemd user manager answering: the unit is written for when one runs.
    NoManager,
    /// Installed but not running.
    Stopped,
    /// Not installed.
    Absent,
}

impl State {
    fn word(&self) -> &'static str {
        match self {
            State::Running => "running",
            State::AtNextLogin => "atNextLogin",
            State::NoManager => "noManager",
            State::Stopped => "stopped",
            State::Absent => "notInstalled",
        }
    }
}

/// What `install`, `uninstall` or `status` found or did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Report {
    pub manager: &'static str,
    pub path: PathBuf,
    pub installed: bool,
    /// The file was written (or removed) by this call.
    pub changed: bool,
    pub state: State,
    /// One line for a person, when there is something to say beyond the state.
    pub note: Option<String>,
}

impl Report {
    fn json(&self) -> Value {
        json!({
            "manager": self.manager,
            "path": self.path.display().to_string(),
            "installed": self.installed,
            "changed": self.changed,
            "state": self.state.word(),
            "note": self.note,
        })
    }

    fn line(&self) -> String {
        let what = if self.manager == "launchd" {
            format!("the {LAUNCHD_LABEL} LaunchAgent")
        } else {
            SYSTEMD_SERVICE.to_owned()
        };
        let state = match self.state {
            State::Running => format!("{what} runs"),
            State::AtNextLogin => format!(
                "{what} is installed and loads at the next login at this Mac's screen (no one is logged in there now); the daemon runs in this session until then"
            ),
            State::NoManager => format!(
                "{what} is written, but no systemd user manager answers here; the daemon runs only while something starts it"
            ),
            State::Stopped => format!("{what} is installed but not running"),
            State::Absent => format!("{what} is not installed"),
        };
        match &self.note {
            Some(note) => format!("{state}; {note}"),
            None => state,
        }
    }
}

/// The LaunchAgent's path under `home`.
pub(crate) fn plist_path(home: &Path) -> PathBuf {
    home.join("Library/LaunchAgents").join(format!("{LAUNCHD_LABEL}.plist"))
}

/// The user unit's path under `home`.
pub(crate) fn unit_path(home: &Path) -> PathBuf {
    home.join(".config/systemd/user").join(SYSTEMD_SERVICE)
}

/// `host setup`'s plist for `home` (XML-escaped: a home is data, not markup).
pub(crate) fn plist_text(home: &Path) -> String {
    let home = home.display().to_string();
    let home = home.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
    hosts::PLIST.replace("__HOME__", &home)
}

/// What `install` does with the unit file it finds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum UnitFile {
    /// None there, or one an earlier acpmux wrote: write this build's.
    Write,
    /// This build's text already.
    Same,
    /// Someone else wrote or edited it: leave it.
    Foreign,
}

pub(crate) fn unit_plan(existing: Option<&str>) -> UnitFile {
    match existing {
        None => UnitFile::Write,
        Some(text) if text == hosts::SYSTEMD_UNIT => UnitFile::Same,
        Some(text) if hosts::OLD_SYSTEMD_UNITS.contains(&text) => UnitFile::Write,
        Some(_) => UnitFile::Foreign,
    }
}

/// Write `text` to `path` unless it already holds it: beside it, then renamed over it, so a
/// full disk never leaves a cut file. True when it wrote.
fn write_if_changed(path: &Path, text: &str) -> Result<bool> {
    if std::fs::read_to_string(path).is_ok_and(|old| old == text) {
        return Ok(false);
    }
    let dir = path.parent().ok_or_else(|| anyhow!("{} has no folder", path.display()))?;
    std::fs::create_dir_all(dir).map_err(|e| anyhow!("cannot make {}: {e}", dir.display()))?;
    let mut new = path.as_os_str().to_owned();
    new.push(".acpmux-new");
    let new = PathBuf::from(new);
    let written = std::fs::write(&new, text).and_then(|()| std::fs::rename(&new, path));
    if let Err(e) = written {
        let _ = std::fs::remove_file(&new);
        return Err(anyhow!("cannot write {}: {e}", path.display()));
    }
    Ok(true)
}

fn ok(out: Option<(i32, String, String)>) -> bool {
    matches!(out, Some((0, _, _)))
}

fn uid() -> u32 {
    #[cfg(unix)]
    {
        // SAFETY: getuid has no preconditions.
        unsafe { libc::getuid() }
    }
    #[cfg(not(unix))]
    {
        0
    }
}

pub(crate) fn install(m: &dyn Machine) -> Result<Report> {
    if m.linux() { install_systemd(m) } else { install_launchd(m, uid()) }
}

fn install_launchd(m: &dyn Machine, uid: u32) -> Result<Report> {
    let home = m.home();
    let path = plist_path(&home);
    let changed = write_if_changed(&path, &plist_text(&home))?;
    let report = |state, note| Report {
        manager: "launchd",
        path: path.clone(),
        installed: true,
        changed,
        state,
        note,
    };
    let domain = format!("gui/{uid}");
    if !ok(m.run("launchctl", &["print", &domain], CALL_WAIT)) {
        return Ok(report(State::AtNextLogin, None));
    }
    let job = format!("{domain}/{LAUNCHD_LABEL}");
    if !changed && ok(m.run("launchctl", &["print", &job], CALL_WAIT)) {
        return Ok(report(State::Running, None));
    }
    // `host setup`'s own reload: refuses (and leaves the daemon) when launchd would not take
    // the job, shuts a daemon that runs outside it down keeping its agents, then bootstraps.
    let script = hosts::launchd_reload(false);
    match m.run("sh", &["-c", &script], RELOAD_WAIT) {
        Some((0, out, _)) if out.contains("ACPMUX_IN_PLACE=") => Err(anyhow!(
            "launchd did not take {LAUNCHD_LABEL}; the daemon runs in this session instead (launchctl bootstrap {domain} {} says why)",
            path.display()
        )),
        Some((0, _, _)) => Ok(report(State::Running, None)),
        Some((_, _, err)) => {
            let why = err.trim();
            Err(anyhow!(
                "launchd did not load {LAUNCHD_LABEL}{}",
                if why.is_empty() { String::new() } else { format!(": {why}") }
            ))
        }
        None => Err(anyhow!("launchd did not load {LAUNCHD_LABEL} in time")),
    }
}

fn install_systemd(m: &dyn Machine) -> Result<Report> {
    let home = m.home();
    let path = unit_path(&home);
    let existing = std::fs::read_to_string(&path).ok();
    let plan = unit_plan(existing.as_deref());
    let changed = match plan {
        UnitFile::Write => write_if_changed(&path, hosts::SYSTEMD_UNIT)?,
        UnitFile::Same | UnitFile::Foreign => false,
    };
    let note = (plan == UnitFile::Foreign)
        .then(|| format!("{} was written by someone else and is left as it is", path.display()));
    let report = |state, note| Report {
        manager: "systemd",
        path: path.clone(),
        installed: true,
        changed,
        state,
        note,
    };
    let systemctl = |args: &[&str]| {
        let mut all = vec!["--user"];
        all.extend_from_slice(args);
        m.run("systemctl", &all, CALL_WAIT)
    };
    if !ok(systemctl(&["daemon-reload"])) {
        return Ok(report(State::NoManager, note));
    }
    if let Some((code, _, err)) = systemctl(&["enable", SYSTEMD_SERVICE])
        && code != 0
    {
        return Err(anyhow!("systemd did not enable {SYSTEMD_SERVICE}: {}", err.trim()));
    }
    if ok(systemctl(&["is-active", "--quiet", SYSTEMD_SERVICE])) {
        // A changed unit applies at its restart; `KillMode=process` keeps the hosted agents.
        if changed && !ok(systemctl(&["restart", SYSTEMD_SERVICE])) {
            return Err(anyhow!("systemd did not restart {SYSTEMD_SERVICE} on its new unit"));
        }
        return Ok(report(State::Running, note));
    }
    if m.daemon_running() {
        // A daemon started another way holds the home's lock: it hands over, keeping its agents.
        let exe = std::env::current_exe()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|_| "acpmux".to_owned());
        let _ = m.run(&exe, &["daemon", "shutdown"], RELOAD_WAIT);
    }
    match systemctl(&["start", SYSTEMD_SERVICE]) {
        Some((0, _, _)) => Ok(report(State::Running, note)),
        Some((_, _, err)) => {
            Err(anyhow!("systemd did not start {SYSTEMD_SERVICE}: {}", err.trim()))
        }
        None => Err(anyhow!("systemd did not start {SYSTEMD_SERVICE} in time")),
    }
}

pub(crate) fn uninstall(m: &dyn Machine) -> Result<Report> {
    let home = m.home();
    if m.linux() {
        let path = unit_path(&home);
        let _ = m.run("systemctl", &["--user", "disable", "--now", SYSTEMD_SERVICE], CALL_WAIT);
        let existing = std::fs::read_to_string(&path).ok();
        let ours = existing.is_some() && unit_plan(existing.as_deref()) != UnitFile::Foreign;
        if ours {
            std::fs::remove_file(&path)
                .map_err(|e| anyhow!("cannot remove {}: {e}", path.display()))?;
        }
        let _ = m.run("systemctl", &["--user", "daemon-reload"], CALL_WAIT);
        let kept = existing.is_some() && !ours;
        return Ok(Report {
            manager: "systemd",
            installed: kept,
            changed: ours,
            state: if kept { State::Stopped } else { State::Absent },
            note: kept.then(|| {
                format!("{} was written by someone else; it is disabled and left", path.display())
            }),
            path,
        });
    }
    let path = plist_path(&home);
    let job = format!("gui/{}/{LAUNCHD_LABEL}", uid());
    let _ = m.run("launchctl", &["bootout", &job], CALL_WAIT);
    let existed = path.is_file();
    if existed {
        std::fs::remove_file(&path)
            .map_err(|e| anyhow!("cannot remove {}: {e}", path.display()))?;
    }
    Ok(Report {
        manager: "launchd",
        path,
        installed: false,
        changed: existed,
        state: State::Absent,
        note: None,
    })
}

pub(crate) fn status(m: &dyn Machine) -> Report {
    let home = m.home();
    if m.linux() {
        let path = unit_path(&home);
        let installed = path.is_file();
        let state = match m.run("systemctl", &["--user", "is-active", SYSTEMD_SERVICE], CALL_WAIT) {
            None => State::NoManager,
            Some((0, _, _)) => State::Running,
            Some(_) if installed => State::Stopped,
            Some(_) => State::Absent,
        };
        return Report { manager: "systemd", path, installed, changed: false, state, note: None };
    }
    let path = plist_path(&home);
    let installed = path.is_file();
    let domain = format!("gui/{}", uid());
    let state =
        if ok(m.run("launchctl", &["print", &format!("{domain}/{LAUNCHD_LABEL}")], CALL_WAIT)) {
            State::Running
        } else if !installed {
            State::Absent
        } else if ok(m.run("launchctl", &["print", &domain], CALL_WAIT)) {
            State::Stopped
        } else {
            State::AtNextLogin
        };
    Report { manager: "launchd", path, installed, changed: false, state, note: None }
}

/// This machine.
pub(crate) struct Here;

impl Machine for Here {
    fn home(&self) -> PathBuf {
        dirs::home_dir().unwrap_or_default()
    }

    fn linux(&self) -> bool {
        cfg!(target_os = "linux")
    }

    fn run(&self, program: &str, args: &[&str], wait: Duration) -> Option<(i32, String, String)> {
        use std::io::Read;
        use std::process::{Command, Stdio};
        use wait_timeout::ChildExt as _;
        let mut child = Command::new(program)
            .args(args)
            // The caller's cmux credential and any join token stay out of the children.
            .env_remove("CMUX_CLOUD_ACCESS_TOKEN")
            .env_remove("CMUX_JOIN")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .ok()?;
        let read = |pipe: Option<Box<dyn Read + Send>>| {
            std::thread::spawn(move || {
                let mut text = String::new();
                if let Some(mut pipe) = pipe {
                    let _ = pipe.read_to_string(&mut text);
                }
                text
            })
        };
        let out = read(child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
        let err = read(child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
        let status = match child.wait_timeout(wait).ok()? {
            Some(status) => status,
            None => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        };
        Some((
            status.code().unwrap_or(-1),
            out.join().unwrap_or_default(),
            err.join().unwrap_or_default(),
        ))
    }

    fn daemon_running(&self) -> bool {
        #[cfg(unix)]
        {
            std::os::unix::net::UnixStream::connect(crate::config::socket_path()).is_ok()
        }
        #[cfg(not(unix))]
        {
            false
        }
    }
}

/// `acpmux daemon service ACTION`.
pub(crate) fn run(action: ServiceAction, json_out: bool) -> Result<()> {
    if !cfg!(unix) {
        return Err(anyhow!("the daemon service is macOS and Linux only"));
    }
    let report = match action {
        ServiceAction::Install => install(&Here)?,
        ServiceAction::Uninstall => uninstall(&Here)?,
        ServiceAction::Status => status(&Here),
    };
    if json_out {
        crate::cli::output::print_json(&report.json());
    } else {
        println!("{}", report.line());
    }
    Ok(())
}

#[cfg(test)]
#[path = "daemon_service_tests.rs"]
mod tests;
