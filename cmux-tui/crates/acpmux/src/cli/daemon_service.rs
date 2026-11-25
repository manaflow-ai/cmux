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
//!
//! On Windows it is a per-user logon task in Task Scheduler, `\acpmux` ([`TASK_NAME`]), that runs
//! `acpmux daemon start` at this user's logon (the start detaches the daemon with a hidden
//! console, `daemon/windows.rs`). It needs no administrator: the task runs as this user with
//! their interactive token at least privilege, never longer than the start itself. Its XML
//! ([`task_xml`]) stays beside the home as the record of what was registered. Where Task
//! Scheduler refuses the registration (a policy that keeps standard users from making tasks),
//! the same command goes in this user's `HKCU\...\Run` key ([`RUN_KEY`]), which also starts it at
//! logon. `install` does not start the daemon; the join line starts it right after.

use crate::cli::hosts;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The launchd label and systemd unit `host setup` uses too.
pub(crate) const LAUNCHD_LABEL: &str = "com.acpmux.daemon";
pub(crate) const SYSTEMD_SERVICE: &str = "acpmux.service";
/// The Windows logon task's name in Task Scheduler's root folder.
pub(crate) const TASK_NAME: &str = "acpmux";
/// Where the fallback logon entry goes when Task Scheduler refuses the task: this user's Run key,
/// value [`TASK_NAME`].
pub(crate) const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";

/// What `daemon service` does.
#[derive(clap::Subcommand, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceAction {
    /// Install (or refresh) the LaunchAgent, user systemd unit or Windows logon task, and start the
    /// daemon under it (on Windows it starts at the next logon; `daemon start` starts it now).
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
    /// Windows: the logon task (or the Run key) instead of launchd or systemd.
    fn windows(&self) -> bool {
        false
    }
    /// The acpmux binary the service starts.
    fn exe(&self) -> PathBuf {
        std::env::current_exe().unwrap_or_else(|_| PathBuf::from("acpmux"))
    }
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
        let what = match self.manager {
            "launchd" => format!("the {LAUNCHD_LABEL} LaunchAgent"),
            "task" => format!("the {TASK_NAME} logon task"),
            "run-key" => format!("the {TASK_NAME} logon entry in {RUN_KEY}"),
            _ => SYSTEMD_SERVICE.to_owned(),
        };
        let state = match self.state {
            State::Running => format!("{what} runs"),
            State::AtNextLogin if self.manager == "task" || self.manager == "run-key" => format!(
                "{what} is installed and starts the daemon at each logon; `acpmux daemon start` starts it now"
            ),
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

/// The logon task's XML record under `home` (the OS account home, as the plist's).
pub(crate) fn task_path(home: &Path) -> PathBuf {
    crate::config::default_home_in(home).join("logon-task.xml")
}

/// XML-escaped text: a user or a path is data, not markup.
fn xml_text(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

/// The logon task for `user` (`DOMAIN\name`, as `whoami` prints it) that runs `exe daemon start`:
/// at that user's logon only, as that user with their interactive token at least privilege, one
/// instance, on battery too, with no time limit (the start itself ends at once; the daemon it
/// starts is not the task's).
pub(crate) fn task_xml(user: &str, exe: &Path) -> String {
    let user = xml_text(user);
    let exe = xml_text(&exe.display().to_string());
    format!(
        r#"<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Starts this machine's acpmux daemon at logon, so cmux can reach it.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>{user}</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>{user}</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>{exe}</Command>
      <Arguments>daemon start</Arguments>
    </Exec>
  </Actions>
</Task>
"#
    )
}

/// `text` as Task Scheduler reads an XML file: UTF-16LE with its byte order mark.
pub(crate) fn utf16_file(text: &str) -> Vec<u8> {
    let mut bytes = vec![0xFF, 0xFE];
    for unit in text.encode_utf16() {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    bytes
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
    write_bytes_if_changed(path, text.as_bytes())
}

fn write_bytes_if_changed(path: &Path, text: &[u8]) -> Result<bool> {
    if std::fs::read(path).is_ok_and(|old| old == text) {
        return Ok(false);
    }
    let dir = path.parent().ok_or_else(|| anyhow!("{} has no folder", path.display()))?;
    crate::home_fs::create_dirs(dir).map_err(|e| anyhow!("cannot make {}: {e}", dir.display()))?;
    let mut new = path.as_os_str().to_owned();
    new.push(".acpmux-new");
    let new = PathBuf::from(new);
    let written =
        crate::home_fs::write(&new, text).and_then(|()| crate::home_fs::rename(&new, path));
    if let Err(e) = written {
        let _ = crate::home_fs::remove_file(&new);
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
    if m.windows() {
        install_task(m)
    } else if m.linux() {
        install_systemd(m)
    } else {
        install_launchd(m, uid())
    }
}

/// This user as Task Scheduler names them: `whoami`'s `DOMAIN\name`, else the environment's.
fn task_user(m: &dyn Machine) -> Option<String> {
    let from_whoami = m.run("whoami", &[], CALL_WAIT).and_then(|(code, out, _)| {
        let user = out.trim().to_owned();
        (code == 0 && !user.is_empty() && !user.contains(['\r', '\n'])).then_some(user)
    });
    from_whoami.or_else(|| {
        let name = std::env::var("USERNAME").ok().filter(|n| !n.is_empty())?;
        Some(match std::env::var("USERDOMAIN").ok().filter(|d| !d.is_empty()) {
            Some(domain) => format!("{domain}\\{name}"),
            None => name,
        })
    })
}

fn run_key_command(exe: &Path) -> String {
    format!("\"{}\" daemon start", exe.display())
}

fn install_task(m: &dyn Machine) -> Result<Report> {
    let home = m.home();
    let path = task_path(&home);
    let exe = m.exe();
    let user = task_user(m).ok_or_else(|| anyhow!("cannot tell which Windows user this is"))?;
    let changed = write_bytes_if_changed(&path, &utf16_file(&task_xml(&user, &exe)))?;
    let state = if m.daemon_running() { State::Running } else { State::AtNextLogin };
    let report = |manager, changed, note| Report {
        manager,
        path: path.clone(),
        installed: true,
        changed,
        state: state.clone(),
        note,
    };
    if !changed && ok(m.run("schtasks", &["/Query", "/TN", TASK_NAME], CALL_WAIT)) {
        return Ok(report("task", false, None));
    }
    let xml = path.display().to_string();
    let created = m.run("schtasks", &["/Create", "/TN", TASK_NAME, "/XML", &xml, "/F"], CALL_WAIT);
    if ok(created.clone()) {
        // A logon entry an earlier fallback wrote is the task's now.
        let _ = m.run("reg", &["delete", RUN_KEY, "/v", TASK_NAME, "/f"], CALL_WAIT);
        return Ok(report("task", true, None));
    }
    let why =
        created.map(|(_, out, err)| format!("{} {}", out.trim(), err.trim()).trim().to_owned());
    let command = run_key_command(&exe);
    let set = m.run(
        "reg",
        &["add", RUN_KEY, "/v", TASK_NAME, "/t", "REG_SZ", "/d", &command, "/f"],
        CALL_WAIT,
    );
    if ok(set) {
        let note = format!(
            "Task Scheduler did not take the task{}; the Run key starts the daemon at logon instead",
            why.filter(|w| !w.is_empty()).map(|w| format!(" ({w})")).unwrap_or_default()
        );
        return Ok(report("run-key", true, Some(note)));
    }
    Err(anyhow!(
        "neither Task Scheduler nor the Run key took the {TASK_NAME} logon start{}",
        why.filter(|w| !w.is_empty()).map(|w| format!(": {w}")).unwrap_or_default()
    ))
}

fn uninstall_task(m: &dyn Machine) -> Result<Report> {
    let path = task_path(&m.home());
    let task = ok(m.run("schtasks", &["/Delete", "/TN", TASK_NAME, "/F"], CALL_WAIT));
    let key = ok(m.run("reg", &["delete", RUN_KEY, "/v", TASK_NAME, "/f"], CALL_WAIT));
    let record = path.is_file();
    if record {
        crate::home_fs::remove_file(&path)
            .map_err(|e| anyhow!("cannot remove {}: {e}", path.display()))?;
    }
    if m.daemon_running() {
        // As systemd's `disable --now`: the daemon stops; its hosted agents keep running.
        let exe = m.exe().display().to_string();
        let _ = m.run(&exe, &["daemon", "shutdown"], RELOAD_WAIT);
    }
    Ok(Report {
        manager: "task",
        path,
        installed: false,
        changed: task || key || record,
        state: State::Absent,
        note: None,
    })
}

fn status_task(m: &dyn Machine) -> Report {
    let path = task_path(&m.home());
    let task = ok(m.run("schtasks", &["/Query", "/TN", TASK_NAME], CALL_WAIT));
    let key = !task && ok(m.run("reg", &["query", RUN_KEY, "/v", TASK_NAME], CALL_WAIT));
    let installed = task || key;
    let state = if m.daemon_running() {
        State::Running
    } else if installed {
        State::AtNextLogin
    } else {
        State::Absent
    };
    let manager = if key { "run-key" } else { "task" };
    Report { manager, path, installed, changed: false, state, note: None }
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
    if m.windows() {
        return uninstall_task(m);
    }
    let home = m.home();
    if m.linux() {
        let path = unit_path(&home);
        let _ = m.run("systemctl", &["--user", "disable", "--now", SYSTEMD_SERVICE], CALL_WAIT);
        let existing = std::fs::read_to_string(&path).ok();
        let ours = existing.is_some() && unit_plan(existing.as_deref()) != UnitFile::Foreign;
        if ours {
            crate::home_fs::remove_file(&path)
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
        crate::home_fs::remove_file(&path)
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
    if m.windows() {
        return status_task(m);
    }
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

    fn windows(&self) -> bool {
        cfg!(windows)
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
        #[cfg(windows)]
        {
            cmux::local_socket::connect_same_user(&crate::config::socket_path()).is_ok()
        }
        #[cfg(not(any(unix, windows)))]
        {
            false
        }
    }
}

/// `acpmux daemon service ACTION`.
pub(crate) fn run(action: ServiceAction, json_out: bool) -> Result<()> {
    if !cfg!(any(unix, windows)) {
        return Err(anyhow!("the daemon service is macOS, Linux and Windows only"));
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
