//! The `update` step (cli/host_enroll_update.rs): what each kind of host
//! says, a doctor that changes nothing, and an enroll that installs the
//! timer on a Linux host whose daemon was already running.

use super::*;
use crate::cli::hosts::RemoteOut;
use anyhow::Result;
use std::cell::{Cell, RefCell};
use std::path::Path;

/// A host whose probe answers `found` (`timer` turns on once the timer
/// was installed); it logs the scripts that ran under the update lock.
struct Host {
    found: &'static [&'static str],
    installed: Cell<bool>,
    /// What the install script prints.
    install_out: &'static str,
    fenced: RefCell<Vec<String>>,
    locked: bool,
}

impl Host {
    fn new(found: &'static [&'static str]) -> Self {
        Self {
            found,
            installed: Cell::new(false),
            install_out: "",
            fenced: RefCell::default(),
            locked: false,
        }
    }
}

impl Remote for Host {
    fn host(&self) -> &str {
        "leo@box.tail"
    }
    fn exec(&self, script: &str, _stdin: Option<&[u8]>) -> Result<RemoteOut> {
        if let Some(inner) = crate::cli::hosts::unfence(script) {
            self.fenced.borrow_mut().push(inner.to_owned());
            assert_eq!(inner, crate::cli::hosts::install_script());
            self.installed.set(true);
            return Ok(RemoteOut {
                ok: true,
                stdout: self.install_out.into(),
                stderr: String::new(),
            });
        }
        assert_eq!(script, probe_script(), "only the probe runs outside the lock");
        let mut words: Vec<String> = self.found.iter().map(|w| format!("{MARK}{w}")).collect();
        if self.installed.get() && self.install_out.is_empty() {
            words.push(format!("{MARK}timer"));
        }
        Ok(RemoteOut {
            ok: true,
            stdout: format!("Welcome to box\n{}\n", words.join("\n")),
            stderr: String::new(),
        })
    }
    fn push(&self, _local: &Path, _remote: &str) -> Result<()> {
        unreachable!("the update step pushes nothing")
    }
    fn spawn(&self, _script: &str) -> Result<std::process::Child> {
        use std::process::{Command, Stdio};
        let answer = if self.locked {
            "echo ACPMUX_UPDATE_RUNNING"
        } else {
            "echo ACPMUX_UPDATE_LOCKED; exec cat >/dev/null"
        };
        Ok(Command::new("sh")
            .args(["-c", answer])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()?)
    }
}

#[test]
fn the_probe_reads_only_its_own_lines() {
    let found = parse(&format!("motd: os=Plan9\n{MARK}os=Linux\n{MARK}systemd\n{MARK}timer\n"));
    assert_eq!(found, Found { os: "Linux".into(), systemd: true, timer: true, ..Found::default() });
    let script = probe_script();
    assert!(
        script.contains("/etc/cmux/vm-kind") && script.contains("~/.acpmux/no-auto-update"),
        "{script}"
    );
}

#[test]
fn each_kind_of_host_says_how_it_stays_current() {
    for fix in [false, true] {
        let mac = Host::new(&["os=Darwin", "systemd"]);
        let r = update(&mac, fix);
        assert_eq!((r.step, r.state), (Step::Update, StepState::Ok));
        assert!(r.detail.starts_with("a Mac:"), "{r:?}");

        let cloud = Host::new(&["os=Linux", "cloud", "systemd"]);
        let r = update(&cloud, fix);
        assert_eq!(r.state, StepState::Ok);
        assert!(r.detail.contains("cmux Cloud VM"), "{r:?}");

        let timer = Host::new(&["os=Linux", "systemd", "timer"]);
        let r = update(&timer, fix);
        assert_eq!(r.state, StepState::Ok);
        assert!(r.detail.contains("every 15 minutes"), "{r:?}");

        let off = Host::new(&["os=Linux", "off", "systemd"]);
        let r = update(&off, fix);
        assert_eq!(r.state, StepState::Skip, "turned off by the person: left off");
        assert!(r.fix.as_deref().unwrap().contains("Remove ~/.acpmux/no-auto-update"), "{r:?}");

        let no_systemd = Host::new(&["os=Linux"]);
        let r = update(&no_systemd, fix);
        assert_eq!(r.state, StepState::Warn);
        assert!(r.detail.contains("no user systemd"), "{r:?}");

        for host in [mac, cloud, timer, off, no_systemd] {
            assert!(host.fenced.borrow().is_empty(), "nothing installed");
        }
    }
}

#[test]
fn doctor_reports_a_missing_timer_and_changes_nothing() {
    let host = Host::new(&["os=Linux", "systemd"]);
    let r = update(&host, false);
    assert_eq!(r.state, StepState::Warn, "a host without the timer still works");
    assert!(r.fix.as_deref().unwrap().contains("--fix"), "{r:?}");
    assert!(host.fenced.borrow().is_empty());
    let report = crate::cli::host_steps::Report::new("box", "leo@box.tail", vec![r]);
    assert!(report.ok);
}

#[test]
fn enroll_installs_the_timer_under_the_update_lock() {
    let host = Host::new(&["os=Linux", "systemd"]);
    let r = update(&host, true);
    assert_eq!((r.step, r.state), (Step::Update, StepState::Fixed), "{r:?}");
    assert!(r.detail.starts_with("installed acpmux-update.timer"), "{r:?}");
    assert_eq!(host.fenced.borrow().len(), 1, "one install, fenced for the lease");
    assert_eq!(serde_json::to_value(&r).unwrap()["step"], "update");
}

#[test]
fn a_unit_someone_else_wrote_is_left_alone_and_said() {
    let mut host = Host::new(&["os=Linux", "systemd"]);
    host.install_out = "ACPMUX_AUTO_UPDATE_OFF=/etc/systemd/user/acpmux-update.timer is a unit acpmux did not write, so this host does not update itself: remove it, then run host update again";
    let r = update(&host, true);
    assert_eq!(r.state, StepState::Warn);
    assert!(
        r.detail
            .starts_with("/etc/systemd/user/acpmux-update.timer is a unit acpmux did not write"),
        "{r:?}"
    );
}

#[test]
fn an_enabled_timer_acpmux_did_not_write_is_not_counted_or_replaced() {
    for fix in [false, true] {
        let host = Host::new(&["os=Linux", "systemd", "foreign"]);
        let r = update(&host, fix);
        assert_eq!(r.state, StepState::Warn, "{r:?}");
        assert!(r.detail.contains("acpmux did not write"), "{r:?}");
        assert!(r.fix.as_deref().unwrap().starts_with("Remove that timer"), "{r:?}");
        assert!(host.fenced.borrow().is_empty(), "nothing written over it");
    }
    let script = probe_script();
    assert!(
        script.contains("FragmentPath")
            && script.contains(crate::cli::hosts::UPDATE_SERVICE)
            && script.contains(crate::cli::hosts::UPDATE_TIMER),
        "own units are told apart by where they load from and their text: {script}"
    );
}

#[test]
fn another_update_holding_the_lock_is_a_warning() {
    let mut host = Host::new(&["os=Linux", "systemd"]);
    host.locked = true;
    let r = update(&host, true);
    assert_eq!(r.state, StepState::Warn);
    assert!(r.detail.contains("another update of leo@box.tail is running"), "{r:?}");
    assert!(host.fenced.borrow().is_empty());
}
