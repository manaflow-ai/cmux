//! `cmux care` on this machine, outside the daemon: the one place that builds a
//! [`cmux_worktree_care::care::Config`] (the daemon's care worker and the
//! headless `acpmux care tick` share it), the headless tick, and the
//! timer that runs the tick every five minutes where no daemon does (a lane
//! VM): a systemd --user timer on Linux, a LaunchAgent on macOS.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_worktree_care::Store;
use cmux_worktree_care::care::{self, Config};
use cmux_worktree_care::inventory::now_ms;
use cmux_worktree_care::policy::{Pressure, Session, Settings};
use cmux_worktree_care::schedule::Refused;

/// How often the timer (and the daemon's care worker) looks at the disk.
pub const TICK_SECS: u64 = 300;

pub const SETTING_CLEAN_BUILD_CACHES: &str = "worktrees.cleanBuildCaches";
pub const SETTING_AUTO_CLEANUP: &str = "worktrees.autoCleanup";
pub const FAMILY_SETTING_PREFIX: &str = "care.families.";

/// Whether automatic passes are on: the setting, else on; an unreadable file turns them off.
pub fn auto_cleanup_enabled() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Missing => true,
        crate::user_settings::Settings::Unreadable(_) => false,
        crate::user_settings::Settings::Parsed(doc) => {
            crate::user_settings::value(&doc, SETTING_AUTO_CLEANUP)
                .and_then(|v| v.as_bool())
                .unwrap_or(true)
        }
    }
}

/// Whether regenerable caches may be removed: on unless the setting says false
/// (the default was off before `cmux care`); an unreadable file keeps them.
pub fn clean_build_caches_enabled() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Missing => true,
        crate::user_settings::Settings::Unreadable(_) => false,
        crate::user_settings::Settings::Parsed(doc) => {
            crate::user_settings::value(&doc, SETTING_CLEAN_BUILD_CACHES)
                .and_then(|v| v.as_bool())
                .unwrap_or(true)
        }
    }
}

/// Families switched off with `care.families.<name>: false`.
/// Read raw: the settings schema does not list them yet.
pub fn families_off() -> Vec<String> {
    let crate::user_settings::Settings::Parsed(doc) = crate::user_settings::read() else {
        return Vec::new();
    };
    let mut names: Vec<&'static str> = vec![care::WORKTREES];
    names.extend(cmux_worktree_care::caches::family_names());
    names
        .into_iter()
        .filter(|name| {
            crate::user_settings::value(&doc, &format!("{FAMILY_SETTING_PREFIX}{name}"))
                .and_then(|v| v.as_bool())
                == Some(false)
        })
        .map(String::from)
        .collect()
}

/// The folders holding plain clones the lane-clones family reads.
pub fn clone_roots(home: &Path) -> Vec<PathBuf> {
    let mut roots = vec![home.join("src")];
    roots.retain(|r| r.is_dir());
    roots
}

pub struct Ask {
    pub apply: bool,
    pub only: Vec<PathBuf>,
    pub only_families: Vec<String>,
    pub roots: Vec<PathBuf>,
    pub pressure: Option<Pressure>,
}

/// The config of a run over this machine; `live` are sessions a daemon knows beyond those on disk.
pub fn config(
    home: &Path,
    store: Store,
    live: Vec<Session>,
    daemon_home: Option<&Path>,
    ask: Ask,
) -> Config {
    let mut sessions = live;
    sessions.extend(crate::worktree_sessions::on_disk(home, daemon_home));
    let configs = crate::worktree_sessions::state_configs(home);
    let roots = if ask.roots.is_empty() {
        crate::worktree_sessions::default_roots(home)
    } else {
        ask.roots
    };
    let pass = cmux_worktree_care::pass::Options {
        roots,
        sessions,
        uses: crate::worktree_sessions::uses(crate::worktree_sessions::claude_homes(
            home, &configs,
        )),
        open: Arc::new(cmux_worktree_care::procs::open_inside),
        guarded: Arc::new(crate::protected_folders::in_protected_location),
        // No daemon (a lane VM, the timer): liveness comes from activity age.
        settings: Settings { headless: daemon_home.is_none(), ..Settings::default() },
        apply: ask.apply,
        pressure: ask.pressure,
        only: ask.only,
        still: None,
        measure: true,
    };
    Config {
        pass,
        home: home.to_path_buf(),
        store,
        apply: ask.apply,
        only_families: ask.only_families,
        off: families_off(),
        clean_caches: clean_build_caches_enabled(),
        clone_roots: clone_roots(home),
        pressure: ask.pressure,
    }
}

pub fn store() -> Result<Store, String> {
    Store::open(Store::default_dir().ok_or("no home folder")?)
}

/// What a tick did.
#[derive(Debug)]
pub enum Tick {
    Off,
    NotDue { used: f64, next_in_ms: u64 },
    Ran(Box<care::Report>),
}

/// One headless tick: sample the disk, and run a pass when one is due, under the machine's
/// claim and stamp (the daemon's worker takes the same).
pub fn tick(force: bool) -> Result<Tick, String> {
    let home = dirs::home_dir().ok_or("no home folder")?;
    let store = store()?;
    let settings = Settings::default();
    let look = care::look(&home, &store, &settings).ok_or("cannot read the disk's size")?;
    if !force && !auto_cleanup_enabled() {
        return Ok(Tick::Off);
    }
    let claim = match care::due(&store, &look) {
        Ok(claim) => claim,
        Err(Refused::Unavailable(error)) => return Err(error),
        Err(Refused::Busy | Refused::NotDue) => {
            return Ok(Tick::NotDue {
                used: look.usage.used_fraction(),
                next_in_ms: look.plan.spacing_ms,
            });
        }
    };
    let config = config(
        &home,
        store,
        Vec::new(),
        None,
        Ask {
            apply: true,
            only: Vec::new(),
            only_families: Vec::new(),
            roots: Vec::new(),
            pressure: None,
        },
    );
    let report = care::run(&config, Some(&look));
    if let Err(error) = claim.finish(now_ms()) {
        eprintln!("acpmux: could not record the care pass: {error}");
    }
    report.map(|r| Tick::Ran(Box::new(r)))
}

// ---- the timer ----

pub const UNIT: &str = "cmux-care";
pub const LABEL: &str = "com.cmux.care";

pub fn systemd_service(exe: &Path) -> String {
    format!(
        "[Unit]\nDescription=cmux care: keep this machine's disk under budget\n\n[Service]\nType=oneshot\nNice=10\nIOSchedulingClass=idle\nExecStart={} care tick\n",
        systemd_quote(&exe.to_string_lossy())
    )
}

/// One `ExecStart=` word: double-quoted, `\` and `"` escaped, `%` doubled
/// (a specifier otherwise), `$` doubled (a variable otherwise), so a path
/// with spaces or those characters stays one program path.
fn systemd_quote(word: &str) -> String {
    let mut out = String::with_capacity(word.len() + 2);
    out.push('"');
    for c in word.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '%' => out.push_str("%%"),
            '$' => out.push_str("$$"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Text for a plist `<string>`.
fn xml_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            _ => out.push(c),
        }
    }
    out
}

pub fn systemd_timer() -> String {
    format!(
        "[Unit]\nDescription=cmux care tick every {m} minutes\n\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec={m}min\nAccuracySec=30s\n\n[Install]\nWantedBy=timers.target\n",
        m = TICK_SECS / 60
    )
}

pub fn launch_agent(exe: &Path) -> String {
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>Label</key><string>{LABEL}</string>\n  <key>ProgramArguments</key>\n  <array><string>{}</string><string>care</string><string>tick</string></array>\n  <key>StartInterval</key><integer>{TICK_SECS}</integer>\n  <key>RunAtLoad</key><true/>\n  <key>ProcessType</key><string>Background</string>\n  <key>LowPriorityIO</key><true/>\n  <key>Nice</key><integer>10</integer>\n</dict>\n</plist>\n",
        xml_escape(&exe.to_string_lossy())
    )
}

/// Writes `content` to `path` unless it already holds it; whether it wrote.
fn write_if_changed(path: &Path, content: &str) -> Result<bool, String> {
    let same = crate::home_fs::OpenOptions::new()
        .read(true)
        .open(path)
        .ok()
        .and_then(|mut file| {
            use std::io::Read as _;
            let mut old = String::new();
            file.read_to_string(&mut old).ok().map(|_| old == content)
        })
        .unwrap_or(false);
    if same {
        return Ok(false);
    }
    if let Some(dir) = path.parent() {
        crate::home_fs::create_dirs(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    crate::home_fs::write(path, content).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(true)
}

/// Where the timer's files go and what they hold, for `home` and the binary `exe`.
pub fn timer_files(home: &Path, exe: &Path, macos: bool) -> Vec<(PathBuf, String)> {
    if macos {
        vec![(home.join("Library/LaunchAgents").join(format!("{LABEL}.plist")), launch_agent(exe))]
    } else {
        let dir = home.join(".config/systemd/user");
        vec![
            (dir.join(format!("{UNIT}.service")), systemd_service(exe)),
            (dir.join(format!("{UNIT}.timer")), systemd_timer()),
        ]
    }
}

fn command(program: &str, args: &[&str]) -> Result<(), String> {
    let out = std::process::Command::new(program)
        .args(args)
        .output()
        .map_err(|e| format!("{program}: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!(
            "{program} {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

/// Installs the timer (idempotent: files are rewritten only when they differ, the
/// timer is enabled either way) and returns the lines to print.
pub fn install_timer() -> Result<Vec<String>, String> {
    let home = dirs::home_dir().ok_or("no home folder")?;
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let macos = cfg!(target_os = "macos");
    let mut lines = Vec::new();
    for (path, content) in timer_files(&home, &exe, macos) {
        let wrote = write_if_changed(&path, &content)?;
        lines.push(format!("{} {}", if wrote { "wrote" } else { "unchanged" }, path.display()));
    }
    if macos {
        let plist = home.join("Library/LaunchAgents").join(format!("{LABEL}.plist"));
        let uid = std::process::Command::new("id")
            .arg("-u")
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();
        let domain = format!("gui/{uid}");
        let _ = command("launchctl", &["bootout", &format!("{domain}/{LABEL}")]);
        command("launchctl", &["bootstrap", &domain, &plist.to_string_lossy()])?;
        lines.push(format!("loaded {LABEL} every {TICK_SECS}s"));
    } else {
        command("systemctl", &["--user", "daemon-reload"])?;
        command("systemctl", &["--user", "enable", "--now", &format!("{UNIT}.timer")])?;
        lines.push(format!("enabled {UNIT}.timer (every {} minutes)", TICK_SECS / 60));
        if command("loginctl", &["enable-linger", &whoami()]).is_ok() {
            lines.push("enabled linger, so the timer runs with no login session".into());
        }
    }
    Ok(lines)
}

fn whoami() -> String {
    std::env::var("USER").unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_timer_files_run_the_tick_every_five_minutes() {
        let files = timer_files(Path::new("/h"), Path::new("/bin/acpmux"), false);
        assert_eq!(files.len(), 2);
        assert!(files[0].0.ends_with(".config/systemd/user/cmux-care.service"));
        assert!(files[0].1.contains("ExecStart=\"/bin/acpmux\" care tick"));
        assert!(files[1].1.contains("OnUnitActiveSec=5min"));
        let mac = timer_files(Path::new("/h"), Path::new("/bin/acpmux"), true);
        assert!(mac[0].1.contains("<integer>300</integer>"));
        assert!(mac[0].1.contains("<string>care</string><string>tick</string>"));
    }

    #[test]
    fn a_binary_path_with_spaces_or_markup_stays_one_word() {
        let exe = Path::new("/Users/a b/100% \"x\" $HOME/<&>'/acpmux");
        let unit = systemd_service(exe);
        assert!(
            unit.contains(r#"ExecStart="/Users/a b/100%% \"x\" $$HOME/<&>'/acpmux" care tick"#),
            "{unit}"
        );
        let plist = launch_agent(exe);
        assert!(
            plist.contains(
                "<string>/Users/a b/100% &quot;x&quot; $HOME/&lt;&amp;&gt;&apos;/acpmux</string>"
            ),
            "{plist}"
        );
    }

    #[test]
    fn writing_a_file_twice_changes_nothing_the_second_time() {
        let dir = std::env::temp_dir().join(format!("care-timer-{}", now_ms()));
        let path = dir.join("a/b.timer");
        assert!(write_if_changed(&path, "x").unwrap());
        assert!(!write_if_changed(&path, "x").unwrap());
        assert!(write_if_changed(&path, "y").unwrap());
        let _ = std::fs::remove_file(&path);
    }

    #[cfg(unix)]
    #[test]
    fn writing_a_timer_stays_in_the_held_home_after_replacement() {
        crate::lost_home_race_tests::isolated(
            module_path!(),
            "writing_a_timer_stays_in_the_held_home_after_replacement",
            |home| {
                let path = home.join(".config/systemd/user/cmux-care.timer");
                std::fs::create_dir_all(path.parent().unwrap()).unwrap();
                std::fs::write(&path, "old").unwrap();
                crate::config::hold_home();
                crate::lost_home_race_tests::replace(home);

                assert!(!write_if_changed(&path, "old").unwrap());
                assert!(
                    home.with_extension("old")
                        .join(".config/systemd/user/cmux-care.timer")
                        .exists()
                );
                assert!(!path.exists(), "the replacement home stays untouched");

                assert!(write_if_changed(&path, "new").unwrap());
                assert_eq!(
                    std::fs::read_to_string(
                        home.with_extension("old").join(".config/systemd/user/cmux-care.timer")
                    )
                    .unwrap(),
                    "new"
                );
                assert!(!path.exists(), "the replacement home stays untouched");
            },
            |_, _| {},
        );
    }
}
