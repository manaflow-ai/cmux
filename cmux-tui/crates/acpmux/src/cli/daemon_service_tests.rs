use super::*;
use std::cell::RefCell;

/// A machine whose launchctl and systemctl answer from `answers` (by the joined argv; an argv
/// with no answer exits 0), recording every call.
struct Fake {
    home: tempfile::TempDir,
    linux: bool,
    running: bool,
    answers: Vec<(&'static str, Option<(i32, &'static str, &'static str)>)>,
    calls: RefCell<Vec<String>>,
}

impl Fake {
    fn new(linux: bool) -> Self {
        Self {
            home: tempfile::tempdir().unwrap(),
            linux,
            running: false,
            answers: Vec::new(),
            calls: RefCell::default(),
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

    fn run(&self, program: &str, args: &[&str], _wait: Duration) -> Option<(i32, String, String)> {
        // A script is recorded by its program and flag only.
        let argv = if program == "sh" {
            "sh -c SCRIPT".to_owned()
        } else {
            let program = if program.ends_with("acpmux") || program.contains("acpmux-") {
                "acpmux"
            } else {
                program
            };
            std::iter::once(program).chain(args.iter().copied()).collect::<Vec<_>>().join(" ")
        };
        self.calls.borrow_mut().push(argv.clone());
        match self.answers.iter().find(|(a, _)| *a == argv) {
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
