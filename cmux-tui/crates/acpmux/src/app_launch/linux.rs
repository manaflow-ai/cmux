//! Linux: apps are desktop entries, opened from their `Exec` in the desktop session the user's
//! systemd manager knows (its `DISPLAY` or `WAYLAND_DISPLAY`), as a desktop's own launcher does.

use super::desktop_entry;
use super::{App, LaunchRequest, Refusal, Running};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// How long `systemctl --user show-environment` may take.
// timeout: one local systemd query; past it there is no desktop session to open in.
const SYSTEMCTL_BUDGET: Duration = Duration::from_secs(2);
/// How long `cmux-rd linux-host display` may take.
// timeout: it starts the virtual display and waits up to 10 s for its socket; past it there is
// no display to open in.
const DISPLAY_BUDGET: Duration = Duration::from_secs(12);
/// How long a launch watches its program for an exit at once (a missing library, a bad flag).
// timeout: only how long a launch looks for an at-once failure; the app keeps running past it.
const EARLY_EXIT: Duration = Duration::from_millis(700);
/// The session variables a desktop app needs.
const SESSION_VARS: &[&str] = &[
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
    "XDG_RUNTIME_DIR",
    "DBUS_SESSION_BUS_ADDRESS",
    "XDG_SESSION_TYPE",
    "XDG_CURRENT_DESKTOP",
];
/// Launchers whose program says nothing of the app they run.
const WRAPPERS: &[&str] = &["flatpak", "snap", "sh", "bash", "env", "gtk-launch", "gio"];

/// The desktop session's environment, found once per request.
pub(super) struct Session {
    env: Vec<(String, String)>,
}

impl Session {
    /// This daemon's own `DISPLAY` or `WAYLAND_DISPLAY` when it has one, else the user manager's
    /// (a desktop session imports them there at login).
    pub(super) fn find() -> Self {
        let own: Vec<(String, String)> = SESSION_VARS
            .iter()
            .filter_map(|k| std::env::var(k).ok().map(|v| ((*k).to_owned(), v)))
            .collect();
        if has_display(&own) {
            return Self { env: own };
        }
        let mut manager =
            super::output_bounded(&["systemctl", "--user", "show-environment"], SYSTEMCTL_BUDGET)
                .map(|out| session_vars(&out))
                .unwrap_or_default();
        if !display_up(&manager, x11_socket_exists) {
            if let Some(display) = virtual_display() {
                manager.retain(|(k, _)| k != "DISPLAY" && k != "WAYLAND_DISPLAY");
                manager.push(("DISPLAY".to_owned(), display));
            }
        }
        Self { env: manager }
    }

    pub(super) fn check(&self) -> Result<(), Refusal> {
        if has_display(&self.env) {
            Ok(())
        } else {
            Err(Refusal::NoSession("no desktop session (no DISPLAY or WAYLAND_DISPLAY)".into()))
        }
    }

    pub(super) fn open(
        &self,
        app: &App,
        request: &LaunchRequest,
        deadline: Instant,
    ) -> Result<Option<u32>, Refusal> {
        self.check()?;
        let argv = if app.path.extension().is_some_and(|e| e == "desktop") {
            let text = std::fs::read_to_string(&app.path)
                .map_err(|e| Refusal::Failed(format!("{}: {e}", app.path.display())))?;
            let entry = desktop_entry::parse(&text)
                .ok_or_else(|| Refusal::Failed(format!("{} has no Exec", app.path.display())))?;
            desktop_entry::argv(
                &entry.exec,
                &request.args,
                &entry.name,
                &app.path.to_string_lossy(),
            )
            .ok_or_else(|| Refusal::Failed(format!("{}'s Exec is malformed", app.path.display())))?
        } else {
            let mut argv = vec![app.path.to_string_lossy().into_owned()];
            argv.extend(request.args.iter().cloned());
            argv
        };
        let (program, args) =
            argv.split_first().ok_or_else(|| Refusal::Failed("empty Exec".into()))?;
        let mut command = cmux_process::Command::new(program);
        command
            .args(args)
            .envs(self.env.iter().map(|(k, v)| (k, v)))
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::null())
            .stderr(cmux_process::Stdio::null())
            // Its own process group: it outlives this request and the daemon's own signals.
            .process_group(0);
        if let Some(home) = dirs::home_dir() {
            command.current_dir(home);
        }
        let mut child = command.spawn().map_err(|e| Refusal::Failed(format!("{program}: {e}")))?;
        // The app the person asked for: it runs until they quit it, not until this request ends.
        child.detach("an app opened by app launch runs until the person quits it");
        let watch = (Instant::now() + EARLY_EXIT).min(deadline);
        while Instant::now() < watch {
            match child.try_wait() {
                Ok(Some(status)) if !status.success() => {
                    return Err(Refusal::Failed(format!("{program} exited at once ({status})")));
                }
                // A launcher that hands off and exits (a single-instance app's second copy).
                Ok(Some(_)) => return Ok(None),
                // timeout: a poll interval inside EARLY_EXIT, not a deadline.
                Ok(None) => std::thread::sleep(Duration::from_millis(50)),
                Err(e) => return Err(Refusal::Failed(e.to_string())),
            }
        }
        Ok(Some(keep(child, app)))
    }
}

/// The apps this daemon opened that still ran when last looked at, each with the program it is
/// known by (its `Exec` program, else its entry): their owner, so each is reaped once it ends and
/// never stays a zombie of the daemon, and the registry `running` reads. Swept at every launch and
/// list, so it holds at most the apps still running plus those that ended since.
#[allow(clippy::type_complexity)]
static LAUNCHED: std::sync::Mutex<Vec<(cmux_process::Child, PathBuf)>> =
    std::sync::Mutex::new(Vec::new());

/// Registers `child`, the copy of `app` just opened, and gives its pid.
fn keep(child: cmux_process::Child, app: &App) -> u32 {
    let pid = child.id();
    let exe = app.exe.clone().unwrap_or_else(|| app.path.clone());
    let mut launched = LAUNCHED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    launched.retain_mut(|(c, _)| matches!(c.try_wait(), Ok(None)));
    launched.push((child, exe));
    pid
}

fn has_display(env: &[(String, String)]) -> bool {
    env.iter().any(|(k, v)| (k == "DISPLAY" || k == "WAYLAND_DISPLAY") && !v.is_empty())
}

/// Whether `env` names a display that is up: any Wayland display or remote X display, or a
/// local X display `:N` whose socket exists (a virtual display stopped when idle leaves its
/// `DISPLAY` behind).
pub(super) fn display_up(env: &[(String, String)], socket_exists: impl Fn(u32) -> bool) -> bool {
    env.iter().any(|(k, v)| match k.as_str() {
        "WAYLAND_DISPLAY" => !v.is_empty(),
        "DISPLAY" => match local_x_display(v) {
            Some(n) => socket_exists(n),
            None => !v.is_empty(),
        },
        _ => false,
    })
}

/// `N` of a local X display `:N` or `:N.S`.
fn local_x_display(display: &str) -> Option<u32> {
    let number = display.strip_prefix(':')?;
    number.split('.').next()?.parse().ok()
}

fn x11_socket_exists(n: u32) -> bool {
    Path::new(&format!("/tmp/.X11-unix/X{n}")).exists()
}

/// A headless machine's virtual display (hq docs/design/remote-screen-share-zero-touch.md,
/// Linux L2): `cmux-rd linux-host display` starts it when it is down and prints `:N`. None
/// where the share host is not installed or the machine has no display to start.
fn virtual_display() -> Option<String> {
    // Where acpmux installs cmux-rd on a joined machine, else the PATH's.
    let installed = dirs::home_dir().map(|home| home.join(".local/bin/cmux-rd"));
    let program = match installed.filter(|p| p.is_file()) {
        Some(path) => path.to_string_lossy().into_owned(),
        None => "cmux-rd".to_owned(),
    };
    let out = super::output_bounded(&[&program, "linux-host", "display"], DISPLAY_BUDGET)?;
    display_line(&out)
}

/// The `:N` line `cmux-rd linux-host display` prints.
pub(super) fn display_line(out: &str) -> Option<String> {
    out.lines().map(str::trim).find(|l| local_x_display(l).is_some()).map(str::to_owned)
}

/// The [`SESSION_VARS`] of `systemctl --user show-environment`'s `KEY=value` lines.
pub(super) fn session_vars(out: &str) -> Vec<(String, String)> {
    out.lines()
        .filter_map(|line| line.split_once('='))
        .filter(|(k, _)| SESSION_VARS.contains(k))
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect()
}

/// The folders desktop entries are found in, the user's first (XDG Base Directory).
fn folders() -> Vec<PathBuf> {
    let home = dirs::home_dir().unwrap_or_default();
    let data_home = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home.join(".local/share"));
    let data_dirs = std::env::var("XDG_DATA_DIRS")
        .ok()
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    let mut folders = vec![data_home.join("applications")];
    folders.extend(
        data_dirs
            .split(':')
            .filter(|d| d.starts_with('/'))
            .map(|d| Path::new(d).join("applications")),
    );
    folders.push(home.join(".local/share/flatpak/exports/share/applications"));
    folders.push(PathBuf::from("/var/lib/flatpak/exports/share/applications"));
    folders.dedup();
    folders
}

/// Every shown application entry, the first of one id winning (the user's over the system's).
pub(super) fn apps() -> Vec<App> {
    let mut apps: Vec<App> = Vec::new();
    for folder in folders() {
        let Ok(entries) = std::fs::read_dir(&folder) else { continue };
        let mut paths: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|e| e == "desktop"))
            .collect();
        paths.sort();
        for path in paths {
            if apps.len() >= super::MAX_APPS {
                return apps;
            }
            let id = path.file_stem().map(|s| s.to_string_lossy().into_owned());
            if apps.iter().any(|a| a.id == id) {
                continue;
            }
            let Some(entry) =
                std::fs::read_to_string(&path).ok().and_then(|t| desktop_entry::parse(&t))
            else {
                continue;
            };
            if !entry.shown {
                continue;
            }
            apps.push(App { name: entry.name.clone(), id, exe: program(&entry.exec), path });
        }
    }
    apps
}

/// The program an `Exec` runs, as a canonical path, when it names the app (not a wrapper).
fn program(exec: &str) -> Option<PathBuf> {
    let argv = desktop_entry::argv(exec, &[], "", "")?;
    let first = argv.first()?;
    let name = Path::new(first).file_name()?.to_string_lossy();
    if WRAPPERS.contains(&name.as_ref()) {
        return None;
    }
    let path = if first.starts_with('/') {
        PathBuf::from(first)
    } else {
        std::env::split_paths(&std::env::var_os("PATH")?)
            .map(|d| d.join(first))
            .find(|p| p.is_file())?
    };
    path.canonicalize().ok()
}

/// The apps this daemon opened that still run ([`LAUNCHED`]). cmux never scans the machine's
/// processes (plans/cmux-next/pty-holder.md): what it started registers itself, so an app opened
/// some other way does not show as running here.
pub(super) fn running() -> Vec<Running> {
    let mut launched = LAUNCHED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    launched.retain_mut(|(child, _)| matches!(child.try_wait(), Ok(None)));
    launched.iter().map(|(child, exe)| Running { pid: child.id(), exe: exe.clone() }).collect()
}
