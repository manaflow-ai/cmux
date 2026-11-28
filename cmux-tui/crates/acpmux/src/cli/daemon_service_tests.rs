use super::*;
use std::cell::RefCell;

/// A machine whose launchctl and systemctl answer from `answers` (by the joined argv; an argv
/// with no answer exits 0), recording every call.
struct Fake {
    home: tempfile::TempDir,
    linux: bool,
    windows: bool,
    running: bool,
    exe: PathBuf,
    answers: Vec<(&'static str, Option<(i32, &'static str, &'static str)>)>,
    calls: RefCell<Vec<String>>,
    /// The text of every `sh -c` script, in order.
    scripts: RefCell<Vec<String>>,
}

impl Fake {
    fn new(linux: bool) -> Self {
        Self {
            home: tempfile::tempdir().unwrap(),
            linux,
            windows: false,
            running: false,
            exe: PathBuf::from(r"C:\Users\leo & co\.local\bin\acpmux.exe"),
            answers: vec![(PROBE, Some((0, PROBE_RUNS, "")))],
            calls: RefCell::default(),
            scripts: RefCell::default(),
        }
    }

    fn answer(
        mut self,
        argv: &'static str,
        out: Option<(i32, &'static str, &'static str)>,
    ) -> Self {
        self.answers.push((argv, out));
        self
    }

    /// A Windows machine whose `whoami` is `HOST\leo`.
    fn windows() -> Self {
        let mut m = Self::new(false).answer("whoami", Some((0, "host\\leo\r\n", "")));
        m.windows = true;
        m
    }

    fn calls(&self) -> Vec<String> {
        self.calls.borrow().clone()
    }

    fn called(&self, prefix: &str) -> bool {
        self.calls().iter().any(|c| c.starts_with(prefix))
    }
}

impl Machine for Fake {
    fn home(&self) -> PathBuf {
        self.home.path().to_path_buf()
    }

    fn linux(&self) -> bool {
        self.linux
    }

    fn windows(&self) -> bool {
        self.windows
    }

    fn exe(&self) -> PathBuf {
        self.exe.clone()
    }

    fn run(&self, program: &str, args: &[&str], _wait: Duration) -> Option<(i32, String, String)> {
        // A script is recorded by its program and flag only.
        let argv = if program == "sh" {
            let script = args.last().copied().unwrap_or_default();
            self.scripts.borrow_mut().push(script.to_owned());
            if script == crate::cli::host_enroll::guarded_install_script() {
                TIMER.to_owned()
            } else if script == crate::cli::host_enroll::update_probe_script() {
                PROBE.to_owned()
            } else {
                "sh -c SCRIPT".to_owned()
            }
        } else {
            let program = if program.ends_with("acpmux") || program.contains("acpmux-") {
                "acpmux"
            } else {
                program
            };
            std::iter::once(program).chain(args.iter().copied()).collect::<Vec<_>>().join(" ")
        };
        self.calls.borrow_mut().push(argv.clone());
        // The last answer given for an argv wins (`new` gives the timer probe's).
        match self.answers.iter().rev().find(|(a, _)| *a == argv) {
            Some((_, out)) => out.map(|(c, o, e)| (c, o.to_owned(), e.to_owned())),
            None => Some((0, String::new(), String::new())),
        }
    }

    fn daemon_running(&self) -> bool {
        self.running
    }
}

const NO_GUI: Option<(i32, &str, &str)> = Some((113, "", "Could not find domain for port"));

#[test]
fn a_mac_with_no_one_at_the_screen_gets_the_plist_and_keeps_its_daemon() {
    let m = Fake::new(false).answer("launchctl print gui/501", NO_GUI);
    let report = install_launchd(&m, 501).unwrap();
    assert_eq!(report.state, State::AtNextLogin);
    assert!(report.installed && report.changed);
    let text = std::fs::read_to_string(plist_path(m.home.path())).unwrap();
    assert_eq!(text, plist_text(m.home.path()));
    assert!(text.contains(&format!("{}/.local/bin/acpmux", m.home.path().display())));
    assert!(text.contains("<string>com.acpmux.daemon</string>"));
    // Nothing was loaded or stopped: there is no domain to load it into.
    assert_eq!(m.calls(), ["launchctl print gui/501"]);
    assert!(report.line().contains("loads at the next login"), "{}", report.line());
    // Again: nothing to write.
    let again = install_launchd(&m, 501).unwrap();
    assert_eq!(again.state, State::AtNextLogin);
    assert!(!again.changed);
}

#[test]
fn a_mac_with_a_gui_login_loads_the_job_through_the_setup_reload_once() {
    let m = Fake::new(false);
    let report = install_launchd(&m, 501).unwrap();
    assert_eq!(report.state, State::Running);
    assert_eq!(m.calls(), ["launchctl print gui/501", "sh -c SCRIPT"]);
    // Installed and loaded already: idempotent, nothing reloaded.
    let m2 = Fake { home: m.home, ..Fake::new(false) };
    let again = install_launchd(&m2, 501).unwrap();
    assert_eq!(again.state, State::Running);
    assert!(!again.changed);
    assert_eq!(
        m2.calls(),
        ["launchctl print gui/501", "launchctl print gui/501/com.acpmux.daemon"]
    );
}

#[test]
fn a_launchd_refusal_or_an_in_place_start_is_an_error() {
    let refused = Fake::new(false).answer("sh -c SCRIPT", Some((3, "", "launchd refuses")));
    let e = install_launchd(&refused, 501).unwrap_err().to_string();
    assert!(e.contains("launchd refuses"), "{e}");
    let in_place =
        Fake::new(false).answer("sh -c SCRIPT", Some((0, "ACPMUX_IN_PLACE=bootstrapFailed\n", "")));
    let e = install_launchd(&in_place, 501).unwrap_err().to_string();
    assert!(e.contains("runs in this session"), "{e}");
    // The plist is written either way, for the next login.
    assert!(plist_path(in_place.home.path()).is_file());
}

#[test]
fn a_home_is_escaped_in_the_plist() {
    let text = plist_text(Path::new("/Users/a&b"));
    assert!(text.contains("/Users/a&amp;b/.local/bin/acpmux"));
    assert!(!text.contains("a&b"));
}

#[test]
fn linux_writes_enables_and_starts_the_unit() {
    let m = Fake::new(true)
        .answer("systemctl --user is-active --quiet acpmux.service", Some((3, "", "")));
    let report = install_systemd(&m).unwrap();
    assert_eq!(report.state, State::Running);
    assert_eq!(std::fs::read_to_string(unit_path(m.home.path())).unwrap(), hosts::SYSTEMD_UNIT);
    assert_eq!(
        m.calls(),
        [
            "systemctl --user daemon-reload",
            "systemctl --user enable acpmux.service",
            "systemctl --user is-active --quiet acpmux.service",
            "systemctl --user start acpmux.service",
        ]
    );
}

#[test]
fn linux_hands_a_daemon_started_another_way_over_to_the_unit() {
    let mut m = Fake::new(true)
        .answer("systemctl --user is-active --quiet acpmux.service", Some((3, "", "")));
    m.running = true;
    install_systemd(&m).unwrap();
    let calls = m.calls();
    let shutdown = calls.iter().position(|c| c == "acpmux daemon shutdown").expect("shutdown");
    let start = calls.iter().position(|c| c == "systemctl --user start acpmux.service").unwrap();
    assert!(shutdown < start, "{calls:?}");
}

#[test]
fn linux_leaves_an_active_unchanged_unit_running_and_restarts_a_refreshed_one() {
    let m = Fake::new(true);
    std::fs::create_dir_all(unit_path(m.home.path()).parent().unwrap()).unwrap();
    std::fs::write(unit_path(m.home.path()), hosts::SYSTEMD_UNIT).unwrap();
    let same = install_systemd(&m).unwrap();
    assert_eq!(same.state, State::Running);
    assert!(!same.changed);
    assert!(!m.called("systemctl --user restart"));
    assert!(!m.called("systemctl --user start"));

    let old = Fake::new(true);
    std::fs::create_dir_all(unit_path(old.home.path()).parent().unwrap()).unwrap();
    std::fs::write(unit_path(old.home.path()), hosts::OLD_SYSTEMD_UNITS[0]).unwrap();
    let refreshed = install_systemd(&old).unwrap();
    assert!(refreshed.changed);
    assert_eq!(std::fs::read_to_string(unit_path(old.home.path())).unwrap(), hosts::SYSTEMD_UNIT);
    assert!(old.called("systemctl --user restart acpmux.service"));
}

#[test]
fn linux_never_overwrites_a_unit_someone_else_wrote() {
    let m = Fake::new(true);
    let path = unit_path(m.home.path());
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, "[Service]\nExecStart=/opt/acpmux daemon run\n").unwrap();
    let report = install_systemd(&m).unwrap();
    assert!(report.note.as_deref().is_some_and(|n| n.contains("someone else")));
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        "[Service]\nExecStart=/opt/acpmux daemon run\n"
    );
    let gone = uninstall(&m).unwrap();
    assert!(path.is_file(), "a foreign unit is disabled, not removed");
    assert_eq!(gone.state, State::Stopped);
}

#[test]
fn linux_with_no_user_manager_writes_the_unit_and_succeeds() {
    let m = Fake::new(true).answer("systemctl --user daemon-reload", None);
    let report = install_systemd(&m).unwrap();
    assert_eq!(report.state, State::NoManager);
    assert!(unit_path(m.home.path()).is_file());
}

#[test]
fn uninstall_removes_what_install_wrote() {
    let mac = Fake::new(false).answer("launchctl print gui/501", NO_GUI);
    install_launchd(&mac, 501).unwrap();
    let gone = uninstall(&mac).unwrap();
    assert_eq!(gone.state, State::Absent);
    assert!(!plist_path(mac.home.path()).exists());

    let linux = Fake::new(true);
    install_systemd(&linux).unwrap();
    let gone = uninstall(&linux).unwrap();
    assert!(gone.changed);
    assert!(!unit_path(linux.home.path()).exists());
    assert!(linux.called("systemctl --user disable --now acpmux.service"));
}

#[test]
fn status_reads_the_manager() {
    let linux = Fake::new(true)
        .answer("systemctl --user is-active acpmux.service", Some((3, "inactive", "")));
    assert_eq!(status(&linux).state, State::Absent);
    install_systemd(&linux).unwrap();
    assert_eq!(status(&linux).state, State::Stopped);
    let json = status(&linux).json();
    assert_eq!(json["manager"], "systemd");
    assert_eq!(json["installed"], true);
}

#[test]
fn unit_plan_replaces_only_acpmux_written_units() {
    assert_eq!(unit_plan(None), UnitFile::Write);
    assert_eq!(unit_plan(Some(hosts::SYSTEMD_UNIT)), UnitFile::Same);
    for old in hosts::OLD_SYSTEMD_UNITS {
        assert_eq!(unit_plan(Some(old)), UnitFile::Write);
    }
    assert_eq!(unit_plan(Some("[Unit]\n")), UnitFile::Foreign);
}

/// `machine enroll --fix`'s guarded timer install, as a join's service install runs it.
const TIMER: &str = "sh -c TIMER";
/// The timer probe that reads, after it, whether the manager runs the timer.
const PROBE: &str = "sh -c PROBE";
/// The probe's words for a timer the manager has enabled and running.
const PROBE_RUNS: &str = "ACPMUX_AU=begin\nACPMUX_AU=os=Linux\nACPMUX_AU=systemd\nACPMUX_AU=timer\nACPMUX_AU=linger\nACPMUX_AU=checked\n";

#[test]
fn linux_install_ends_with_the_update_timer_and_a_rerun_is_the_same() {
    let m = Fake::new(true)
        .answer("systemctl --user is-active --quiet acpmux.service", Some((3, "", "")));
    let first = install(&m).unwrap();
    assert_eq!(first.state, State::Running);
    assert_eq!(first.note, None);
    let calls = m.calls();
    let start = calls.iter().position(|c| c == "systemctl --user start acpmux.service").unwrap();
    assert_eq!(&calls[start + 1..], [TIMER, PROBE], "the timer once the service runs, then read");
    assert_eq!(
        *m.scripts.borrow(),
        [
            crate::cli::host_enroll::guarded_install_script(),
            crate::cli::host_enroll::update_probe_script()
        ],
        "machine enroll --fix's own install"
    );
    assert!(m.scripts.borrow()[0].contains(&hosts::install_script()), "setup's unit text");
    // A re-run of the join line: the unit is kept, the service left running, the same install
    // (which keeps units with this build's text) run again.
    let again = Fake::new(true);
    std::fs::create_dir_all(unit_path(again.home.path()).parent().unwrap()).unwrap();
    std::fs::write(unit_path(again.home.path()), hosts::SYSTEMD_UNIT).unwrap();
    let rerun = install(&again).unwrap();
    assert_eq!((rerun.state, rerun.changed, rerun.note), (State::Running, false, None));
    assert!(!again.called("systemctl --user restart") && !again.called("systemctl --user start"));
    assert!(again.called(TIMER) && again.called(PROBE));
}

#[test]
fn the_timer_is_left_to_whoever_wrote_the_unit_and_waits_for_a_manager() {
    // A unit someone else wrote: theirs, and so is how it updates.
    let m = Fake::new(true);
    std::fs::create_dir_all(unit_path(m.home.path()).parent().unwrap()).unwrap();
    std::fs::write(unit_path(m.home.path()), "[Service]\nExecStart=/opt/theirs\n").unwrap();
    install(&m).unwrap();
    assert!(!m.called(TIMER), "{:?}", m.calls());
    // No user manager: nothing runs, so no timer either.
    let m = Fake::new(true).answer("systemctl --user daemon-reload", Some((1, "", "no bus")));
    assert_eq!(install(&m).unwrap().state, State::NoManager);
    assert!(!m.called(TIMER));
    // A Mac has no timer.
    let m = Fake::new(false).answer("launchctl print gui/501", NO_GUI);
    let _ = install_launchd(&m, 501);
    assert!(!m.called(TIMER));
}

#[test]
fn a_timer_the_manager_does_not_run_is_never_reported_installed() {
    // The install script could not enable it (its own words).
    let m = Fake::new(true)
        .answer(
            TIMER,
            Some((
                0,
                "ACPMUX_AUTO_UPDATE_OFF=systemctl --user did not enable acpmux-update.timer\n",
                "",
            )),
        )
        .answer(PROBE, Some((0, "ACPMUX_AU=begin\nACPMUX_AU=stopped\nACPMUX_AU=checked\n", "")));
    let report = install(&m).unwrap();
    assert_eq!(report.state, State::Running);
    assert_eq!(report.note.as_deref(), Some("systemctl --user did not enable acpmux-update.timer"));
    assert!(report.line().contains("did not enable acpmux-update.timer"));
    // Silent install, but the manager does not call it enabled and active.
    let m = Fake::new(true)
        .answer(PROBE, Some((0, "ACPMUX_AU=begin\nACPMUX_AU=stopped\nACPMUX_AU=checked\n", "")));
    let note = install(&m).unwrap().note.unwrap();
    assert!(note.contains("not enabled and running"), "{note}");
    // A probe that does not answer is no proof either.
    let m = Fake::new(true).answer(PROBE, None);
    assert!(install(&m).unwrap().note.is_some());
    // The owner's no-auto-update marker: off on purpose, nothing to say.
    let m = Fake::new(true)
        .answer(PROBE, Some((0, "ACPMUX_AU=begin\nACPMUX_AU=off\nACPMUX_AU=checked\n", "")));
    assert_eq!(install(&m).unwrap().note, None);
}

#[test]
fn another_xdg_config_home_or_a_foreign_unit_writes_no_timer_and_says_so() {
    for (words, says) in [
        ("ACPMUX_AU=begin\nACPMUX_AU=xdg\n", "XDG_CONFIG_HOME"),
        ("ACPMUX_AU=begin\nACPMUX_AU=foreign\n", "did not write"),
        ("ACPMUX_AU=begin\nACPMUX_AU=unchecked\n", "could not be read"),
        ("ACPMUX_AU=begin\nACPMUX_AU=nolinger\n", "does not linger"),
    ] {
        let m = Fake::new(true).answer(TIMER, Some((0, words, "")));
        let note = install(&m).unwrap().note.unwrap_or_default();
        assert!(note.contains(says), "{words}: {note}");
        assert!(!m.called(PROBE), "{words}: nothing was installed to read");
    }
}

#[test]
fn a_pair_codes_join_adds_the_timer_only_beside_acpmuxs_own_running_service() {
    // Own unit, running: the timer.
    let m = Fake::new(true);
    std::fs::create_dir_all(unit_path(m.home.path()).parent().unwrap()).unwrap();
    std::fs::write(unit_path(m.home.path()), hosts::SYSTEMD_UNIT).unwrap();
    assert_eq!(ensure_update_timer(&m), None);
    assert!(m.called(TIMER));
    // Not running, or no unit of acpmux's: nothing.
    let stopped = Fake::new(true)
        .answer("systemctl --user is-active --quiet acpmux.service", Some((3, "", "")));
    std::fs::create_dir_all(unit_path(stopped.home.path()).parent().unwrap()).unwrap();
    std::fs::write(unit_path(stopped.home.path()), hosts::SYSTEMD_UNIT).unwrap();
    assert_eq!(ensure_update_timer(&stopped), None);
    assert!(!stopped.called(TIMER));
    let none = Fake::new(true);
    assert_eq!(ensure_update_timer(&none), None);
    assert!(!none.called(TIMER));
    let mac = Fake::new(false);
    assert_eq!(ensure_update_timer(&mac), None);
    assert!(mac.calls().is_empty());
}

/// `hosts::install_script` run for real in a scratch home, with a `systemctl` that answers from
/// the unit files there and records what it was asked.
#[cfg(unix)]
fn run_timer_script(home: &Path, bin: &Path) -> String {
    use std::os::unix::fs::PermissionsExt;
    let fake = bin.join("systemctl");
    std::fs::write(
        &fake,
        r#"#!/bin/sh
echo "$*" >> "$HOME/systemctl.log"
d=$HOME/.config/systemd/user
case "$*" in
  "--user show "*" -p LoadState --value") [ -e "$d/$3" ] && echo loaded || echo not-found ;;
  "--user show "*" -p FragmentPath --value") [ -e "$d/$3" ] && echo "$d/$3" || echo ;;
  "--user enable --now acpmux-update.timer") [ ! -e "$HOME/enable-fails" ] || exit 1; : > "$HOME/enabled" ;;
  "--user disable --now acpmux-update.timer") rm -f "$HOME/enabled" ;;
  "--user is-enabled --quiet acpmux-update.timer") [ -e "$HOME/enabled" ] || exit 1 ;;
esac
exit 0
"#,
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let out = std::process::Command::new("sh")
        .arg("-c")
        .arg(hosts::install_script())
        .env_clear()
        .env("HOME", home)
        .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    String::from_utf8(out.stdout).unwrap()
}

#[test]
#[cfg(unix)]
fn the_timer_script_ends_with_the_timer_enabled_and_a_rerun_changes_nothing() {
    let root = tempfile::tempdir().unwrap();
    let (home, bin) = (root.path().join("home"), root.path().join("bin"));
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&bin).unwrap();
    let units = home.join(".config/systemd/user");
    let log = home.join("systemctl.log");
    let out = run_timer_script(&home, &bin);
    assert_eq!(out, "", "no reason it is off");
    let service = std::fs::read_to_string(units.join("acpmux-update.service")).unwrap();
    let timer = std::fs::read_to_string(units.join("acpmux-update.timer")).unwrap();
    assert_eq!((service.as_str(), timer.as_str()), (hosts::UPDATE_SERVICE, hosts::UPDATE_TIMER));
    let first = std::fs::read_to_string(&log).unwrap();
    assert!(first.contains("--user daemon-reload"), "{first}");
    assert!(first.contains("--user enable --now acpmux-update.timer"), "{first}");
    // The re-run: the same files, kept; no reload; the timer enabled again (a no-op).
    std::fs::remove_file(&log).unwrap();
    let written = std::fs::metadata(units.join("acpmux-update.timer")).unwrap().modified().unwrap();
    assert_eq!(run_timer_script(&home, &bin), "");
    let modified =
        std::fs::metadata(units.join("acpmux-update.timer")).unwrap().modified().unwrap();
    assert_eq!(modified, written, "kept, not rewritten");
    let second = std::fs::read_to_string(&log).unwrap();
    assert!(!second.contains("daemon-reload"), "{second}");
    assert!(second.contains("--user enable --now acpmux-update.timer"), "{second}");
    // The owner's marker turns it off.
    std::fs::create_dir_all(home.join(".acpmux")).unwrap();
    std::fs::write(home.join(".acpmux").join(hosts::NO_AUTO_UPDATE), "").unwrap();
    std::fs::remove_file(&log).unwrap();
    assert_eq!(run_timer_script(&home, &bin), "");
    let off = std::fs::read_to_string(&log).unwrap();
    assert!(off.contains("--user disable --now acpmux-update.timer"), "{off}");
    // A manager that refuses the enable: said, never taken for a running timer.
    std::fs::remove_file(home.join(".acpmux").join(hosts::NO_AUTO_UPDATE)).unwrap();
    std::fs::write(home.join("enable-fails"), "").unwrap();
    let out = run_timer_script(&home, &bin);
    let (_, why) = hosts::take_auto_update_off(&out);
    assert!(why.is_some_and(|why| why.contains("did not enable acpmux-update.timer")), "{out}");
}

/// The UTF-16LE task file `install` wrote, as text.
fn task_file(m: &Fake) -> String {
    let bytes = std::fs::read(task_path(m.home.path())).unwrap();
    assert_eq!(&bytes[..2], &[0xFF, 0xFE], "Task Scheduler reads UTF-16LE with its mark");
    let units: Vec<u16> =
        bytes[2..].chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
    String::from_utf16(&units).unwrap()
}

#[test]
fn windows_install_registers_a_logon_task_for_this_user_only() {
    let m = Fake::windows();
    let report = install(&m).unwrap();
    assert_eq!(report.manager, "task");
    assert!(report.installed && report.changed);
    // Not running yet: the join line starts it, and every logon after.
    assert_eq!(report.state, State::AtNextLogin);
    let xml = task_file(&m);
    assert_eq!(xml.matches("<UserId>host\\leo</UserId>").count(), 2, "{xml}");
    assert!(xml.contains("<LogonType>InteractiveToken</LogonType>"));
    assert!(xml.contains("<RunLevel>LeastPrivilege</RunLevel>"));
    assert!(xml.contains("<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>"));
    // The path is data: escaped, never markup.
    assert!(xml.contains(r"<Command>C:\Users\leo &amp; co\.local\bin\acpmux.exe</Command>"));
    assert!(xml.contains("<Arguments>daemon start</Arguments>"));
    let xml_path = task_path(m.home.path()).display().to_string();
    assert!(
        m.called(&format!("schtasks /Create /TN acpmux /XML {xml_path} /F")),
        "{:?}",
        m.calls()
    );
    assert!(
        m.called(r"reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v acpmux /f")
    );
    assert!(!m.called("systemctl") && !m.called("launchctl"));
}

#[test]
fn windows_install_leaves_a_registered_task_with_the_same_xml() {
    let m = Fake::windows();
    install(&m).unwrap();
    m.calls.borrow_mut().clear();
    let again = install(&m).unwrap();
    assert!(!again.changed);
    assert!(m.called("schtasks /Query /TN acpmux"));
    assert!(!m.called("schtasks /Create"), "{:?}", m.calls());
}

#[test]
fn windows_install_falls_back_to_the_run_key_when_task_scheduler_refuses() {
    let mut m = Fake::windows();
    m.running = true;
    // Any /Create argv: the path is the fake's temporary home.
    let xml_path: &'static str = Box::leak(
        format!("schtasks /Create /TN acpmux /XML {} /F", task_path(m.home.path()).display())
            .into_boxed_str(),
    );
    let m = m.answer(xml_path, Some((1, "", "ERROR: Access is denied.")));
    let report = install(&m).unwrap();
    assert_eq!(report.manager, "run-key");
    assert_eq!(report.state, State::Running);
    assert!(report.note.as_deref().unwrap().contains("Access is denied"));
    assert!(m.called(
        r#"reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v acpmux /t REG_SZ /d "C:\Users\leo & co\.local\bin\acpmux.exe" daemon start /f"#
    ));
}

#[test]
fn windows_uninstall_and_status() {
    let m = Fake::windows()
        .answer(
            "schtasks /Query /TN acpmux",
            Some((1, "", "ERROR: The system cannot find the file specified.")),
        )
        .answer(
            r"reg query HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v acpmux",
            Some((1, "", "")),
        );
    assert_eq!(status(&m).state, State::Absent);
    install(&m).unwrap();
    let gone = uninstall(&m).unwrap();
    assert_eq!(gone.state, State::Absent);
    assert!(gone.changed);
    assert!(!task_path(m.home.path()).exists());
    assert!(m.called("schtasks /Delete /TN acpmux /F"));
}

const NIGHTLY_ACPMUX: &str = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux";

#[test]
fn an_apps_bundled_acpmux_runs_the_launch_agent_from_its_bundle() {
    let home = Path::new("/Users/leo");
    let never = |_: &Path| false;
    let bundled = PathBuf::from(NIGHTLY_ACPMUX);
    assert_eq!(launchd_program(home, &bundled, None, &never), bundled);
    // The multi-call `bin/cmux` the `bin/acpmux` link resolves to: still the link, which runs acpmux.
    let cli = bundled.with_file_name("cmux");
    assert_eq!(launchd_program(home, &cli, None, &never), bundled);
    // A DEV app runs a home of its own; a translocated or temporary copy goes away.
    for exe in [
        "/Applications/cmux DEV.app/Contents/Resources/bin/acpmux",
        "/Applications/cmux DEV tag.app/Contents/Resources/bin/acpmux",
        "/private/var/folders/x/AppTranslocation/1/d/cmux NIGHTLY.app/Contents/Resources/bin/acpmux",
        "/tmp/cmux NIGHTLY.app/Contents/Resources/bin/acpmux",
        "/Users/leo/.local/bin/acpmux",
    ] {
        assert_eq!(
            launchd_program(home, Path::new(exe), None, &never),
            home.join(".local/bin/acpmux"),
            "{exe}"
        );
    }
}

#[test]
fn the_join_keeps_a_launch_agent_an_app_runs_while_that_app_is_there() {
    let home = Path::new("/Users/leo");
    let local = home.join(".local/bin/acpmux");
    let bundled = PathBuf::from(NIGHTLY_ACPMUX);
    let held = plist_for(home, &bundled);
    let there = |p: &Path| p == Path::new(NIGHTLY_ACPMUX);
    // `~/.local/bin/acpmux daemon service install` (the join, `host setup`) does not take it
    // back, so the app never takes it over again: the two agree.
    assert_eq!(launchd_program(home, &local, Some(&held), &there), bundled);
    // The app is gone: back to ~/.local/bin.
    assert_eq!(launchd_program(home, &local, Some(&held), &|_| false), local);
    // A plist of ~/.local/bin, or none, stays ~/.local/bin.
    assert_eq!(launchd_program(home, &local, Some(&plist_text(home)), &there), local);
    assert_eq!(launchd_program(home, &local, None, &there), local);
    // A DEV app's binary in the plist (someone wrote it) is not kept.
    let dev =
        plist_for(home, Path::new("/Applications/cmux DEV.app/Contents/Resources/bin/acpmux"));
    assert_eq!(launchd_program(home, &local, Some(&dev), &|_| true), local);
}

#[test]
fn the_bundled_plist_runs_the_bundle_with_what_the_app_gives_its_daemon() {
    let home = Path::new("/Users/leo");
    let local = home.join(".local/bin/acpmux");
    assert_eq!(plist_for(home, &local), plist_text(home));
    assert_eq!(plist_program(&plist_text(home)), Some(local.clone()));
    let bundled = PathBuf::from(NIGHTLY_ACPMUX);
    let text = plist_for(home, &bundled);
    assert_eq!(plist_program(&text), Some(bundled.clone()));
    assert!(!text.contains(".local/bin/acpmux</string><string>daemon"), "{text}");
    assert!(text.contains(&format!(
        "<array><string>/bin/sh</string><string>-c</string><string>[ -x \"$0\" ] &amp;&amp; exec \"$0\" daemon run; exec \"$1\" daemon run</string><string>{NIGHTLY_ACPMUX}</string><string>/Users/leo/.local/bin/acpmux</string></array>"
    )));
    assert!(text.contains(
        "<key>CMUX_BUNDLED_CLI_PATH</key><string>/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux</string>"
    ));
    assert!(text.contains("<key>ACPMUX_LOCAL_ROUTER</key><string>1</string>"));
    assert!(text.contains("<key>ACPMUX_SECRET_TOOLS</key><string>1</string>"));
    // Kept alive by launchd, with no app.
    assert!(
        text.contains("<key>KeepAlive</key><true/>")
            && text.contains("<key>RunAtLoad</key><true/>")
    );
    // Escaped as data.
    let odd = plist_for(
        Path::new("/Users/a&b"),
        Path::new("/Applications/a&b.app/Contents/Resources/bin/acpmux"),
    );
    assert!(
        odd.contains("<string>/Applications/a&amp;b.app/Contents/Resources/bin/acpmux</string>")
    );
    assert_eq!(
        plist_program(&odd),
        Some(PathBuf::from("/Applications/a&b.app/Contents/Resources/bin/acpmux"))
    );
}

#[test]
fn the_app_installs_its_bundled_acpmux_as_the_launch_agent_and_reloads_through_it() {
    let m = Fake { exe: PathBuf::from(NIGHTLY_ACPMUX), ..Fake::new(false) };
    let report = install_launchd(&m, 501).unwrap();
    assert_eq!(report.state, State::Running);
    assert!(report.changed);
    let text = std::fs::read_to_string(plist_path(m.home.path())).unwrap();
    assert_eq!(plist_program(&text), Some(PathBuf::from(NIGHTLY_ACPMUX)));
    let scripts = m.scripts.borrow().clone();
    assert_eq!(scripts.len(), 1);
    // The reload asks and stops the daemon through the bundle's acpmux (there may be no
    // ~/.local/bin/acpmux), quoted: the path has a space.
    assert!(
        scripts[0].contains(&format!("'{NIGHTLY_ACPMUX}' --json daemon status")),
        "{}",
        scripts[0]
    );
    assert!(!scripts[0].contains("~/.local/bin/acpmux"), "{}", scripts[0]);
    // Again: written already and loaded, so nothing is reloaded.
    let m2 = Fake { home: m.home, exe: PathBuf::from(NIGHTLY_ACPMUX), ..Fake::new(false) };
    let again = install_launchd(&m2, 501).unwrap();
    assert_eq!(again.state, State::Running);
    assert!(!again.changed);
    assert!(m2.scripts.borrow().is_empty());
}

#[test]
fn a_job_launchd_still_runs_from_an_earlier_program_is_reloaded() {
    let stale = Fake {
        exe: PathBuf::from(NIGHTLY_ACPMUX),
        ..Fake::new(false).answer(
            "launchctl print gui/501/com.acpmux.daemon",
            Some((
                0,
                "gui/501/com.acpmux.daemon = {\n\tprogram = /Users/me/.local/bin/acpmux\n}\n",
                "",
            )),
        )
    };
    let path = plist_path(stale.home.path());
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, plist_for(stale.home.path(), Path::new(NIGHTLY_ACPMUX))).unwrap();
    let report = install_launchd(&stale, 501).unwrap();
    assert!(!report.changed);
    assert_eq!(stale.scripts.borrow().len(), 1, "reloaded: {:?}", stale.calls());
    assert_eq!(
        loaded_program(
            "\tprogram = /Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux\n"
        ),
        Some(PathBuf::from(NIGHTLY_ACPMUX))
    );
    assert_eq!(loaded_program("\tstate = running\n"), None);
}

/// A deleted app never leaves launchd retrying a missing binary: the job runs the app's acpmux
/// while it is there, else ~/.local/bin/acpmux. The paths are arguments, not script text, and
/// `exec` leaves the daemon's executable the app's own.
#[test]
#[cfg(unix)]
fn the_app_held_job_falls_back_to_the_local_binary_when_the_app_is_gone() {
    let dir = tempfile::tempdir().unwrap();
    let app = dir.path().join("cmux $(touch pwned).app/Contents/Resources/bin/acpmux");
    let local = dir.path().join("local acpmux");
    let fake = |who: &str| format!("#!/bin/sh\necho \"{who} $*\"\n");
    crate::test_exec::write_executable(&local, fake("local").into_bytes());
    let run = || {
        let out = std::process::Command::new("/bin/sh")
            .args(["-c", FALLBACK_SCRIPT])
            .arg(&app)
            .arg(&local)
            .current_dir(dir.path())
            .output()
            .unwrap();
        String::from_utf8(out.stdout).unwrap()
    };
    assert_eq!(run(), "local daemon run\n", "no app: the fallback");
    std::fs::create_dir_all(app.parent().unwrap()).unwrap();
    crate::test_exec::write_executable(&app, fake("app").into_bytes());
    assert_eq!(run(), "app daemon run\n", "the app's acpmux while it is there");
    assert!(!dir.path().join("pwned").exists(), "a path is never run as script text");
    // The plist's arguments are that script and those two paths, and read back as the app's.
    let home = Path::new("/Users/leo");
    let text = plist_for(home, Path::new(NIGHTLY_ACPMUX));
    assert_eq!(
        plist_arguments(&text).unwrap(),
        ["/bin/sh", "-c", FALLBACK_SCRIPT, NIGHTLY_ACPMUX, "/Users/leo/.local/bin/acpmux"]
    );
    assert_eq!(plist_program(&text), Some(PathBuf::from(NIGHTLY_ACPMUX)));
    assert_eq!(launchd_argv0(home, Path::new(NIGHTLY_ACPMUX)), PathBuf::from("/bin/sh"));
    assert_eq!(launchd_argv0(home, &local_bin(home)), local_bin(home));
}
