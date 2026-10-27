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
    /// Whether the timer runs once installed.
    starts: bool,
}

impl Host {
    fn new(found: &'static [&'static str]) -> Self {
        Self {
            found,
            installed: Cell::new(false),
            install_out: "",
            fenced: RefCell::default(),
            locked: false,
            starts: true,
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
        if self.installed.get() && self.install_out.is_empty() && self.starts {
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

        // Turned off is turned off on a Mac and a Cloud VM too.
        for os in [&["os=Darwin", "off"][..], &["os=Linux", "cloud", "off", "systemd"]] {
            let host = Host::new(os);
            assert_eq!(update(&host, fix).state, StepState::Skip, "{os:?}");
        }

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
        assert!(r.fix.as_deref().unwrap().starts_with("Remove the acpmux-update units"), "{r:?}");
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
fn a_stopped_timer_is_said_and_started() {
    let host = Host::new(&["os=Linux", "systemd", "stopped"]);
    let r = update(&host, false);
    assert_eq!(r.state, StepState::Warn, "{r:?}");
    assert!(r.detail.contains("off or stopped"), "{r:?}");
    assert!(r.fix.as_deref().unwrap().contains("--fix to start"), "{r:?}");
    assert!(host.fenced.borrow().is_empty());

    let r = update(&host, true);
    assert_eq!(r.state, StepState::Fixed, "{r:?}");
    assert_eq!(host.fenced.borrow().len(), 1);

    let mut host = Host::new(&["os=Linux", "systemd"]);
    host.starts = false;
    let r = update(&host, true);
    assert_eq!(r.state, StepState::Warn, "installed but not running: {r:?}");
    assert!(r.detail.contains("not running"), "{r:?}");
}

/// The real probe, run by `sh` against a fake `systemctl` in a scratch home.
mod probe_in_a_shell {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::process::Command;

    /// The timer's units as a user manager and `~/.config/systemd/user` have
    /// them.
    #[derive(Clone, Copy)]
    struct Units {
        /// What `is-enabled` says of the timer.
        enabled: &'static str,
        active: bool,
        /// The manager knows the units (else `not-found`).
        loaded: bool,
        /// Where they load from; `own` is ~/.config/systemd/user.
        frag: &'static str,
        /// The unit that has a drop-in, if one does.
        drop_in: Option<&'static str>,
        /// The files in ~/.config/systemd/user: acpmux's text, another's, or none.
        service: Option<&'static str>,
        timer: Option<&'static str>,
        /// A drop-in directory on disk, under ~/.config/systemd/user.
        drop_in_dir: Option<&'static str>,
    }

    const OWN: Units = Units {
        enabled: "enabled",
        active: true,
        loaded: true,
        frag: "own",
        drop_in: None,
        service: Some(hosts::UPDATE_SERVICE),
        timer: Some(hosts::UPDATE_TIMER),
        drop_in_dir: None,
    };
    const NONE: Units = Units {
        enabled: "",
        active: false,
        loaded: false,
        frag: "",
        drop_in: None,
        service: None,
        timer: None,
        drop_in_dir: None,
    };
    const OTHER_TEXT: &str = "[Service]\nExecStart=/usr/bin/true\n";

    fn probe(u: Units) -> Found {
        static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!("acpmux-probe-{}-{n}", std::process::id()));
        let home = root.join("home");
        let units = home.join(".config/systemd/user");
        let bin = root.join("bin");
        fs::create_dir_all(&units).unwrap();
        fs::create_dir_all(&bin).unwrap();
        for (file, text) in [("acpmux-update.service", u.service), ("acpmux-update.timer", u.timer)]
        {
            if let Some(text) = text {
                fs::write(units.join(file), text).unwrap();
            }
        }
        if let Some(dir) = u.drop_in_dir {
            fs::create_dir_all(units.join(dir)).unwrap();
            fs::write(units.join(dir).join("o.conf"), OTHER_TEXT).unwrap();
        }
        let frag = if u.frag == "own" { units.display().to_string() } else { u.frag.into() };
        let fake = format!(
            r#"#!/bin/sh
[ "$1" = --user ] || exit 2; shift
case "$1" in
show-environment) exit 0 ;;
is-enabled) echo "{enabled}" ;;
is-active) exit {active} ;;
show) case "$4" in
  LoadState) echo {load} ;;
  FragmentPath) [ {load} = loaded ] && echo "{frag}/$2" || echo ;;
  DropInPaths) [ "$2" = "{drop_in}" ] && echo "/x/$2.d/o.conf" || echo ;;
  esac ;;
*) exit 2 ;;
esac
"#,
            enabled = u.enabled,
            active = if u.active { 0 } else { 3 },
            load = if u.loaded { "loaded" } else { "not-found" },
            drop_in = u.drop_in.unwrap_or("-"),
        );
        let systemctl = bin.join("systemctl");
        fs::write(&systemctl, fake).unwrap();
        fs::set_permissions(&systemctl, fs::Permissions::from_mode(0o755)).unwrap();
        let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
        let out = Command::new("sh")
            .arg("-c")
            .arg(probe_script())
            .env("HOME", &home)
            .env("PATH", path)
            .output()
            .unwrap();
        fs::remove_dir_all(&root).unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        parse(&String::from_utf8_lossy(&out.stdout))
    }

    fn kind(found: &Found) -> &'static str {
        assert!(found.systemd, "{found:?}");
        match (found.timer, found.stopped, found.foreign) {
            (true, false, false) => "timer",
            (false, true, false) => "stopped",
            (false, false, true) => "foreign",
            (false, false, false) => "missing",
            _ => panic!("more than one: {found:?}"),
        }
    }

    #[test]
    fn acpmux_own_timer_runs_or_is_stopped() {
        assert_eq!(kind(&probe(OWN)), "timer");
        for u in [
            Units { active: false, ..OWN },
            Units { enabled: "disabled", active: false, ..OWN },
            Units { enabled: "enabled-runtime", ..OWN },
            // A half-written install of acpmux's own text: --fix finishes it.
            Units { timer: None, loaded: false, ..OWN },
        ] {
            assert_eq!(kind(&probe(u)), "stopped");
        }
        assert_eq!(kind(&probe(NONE)), "missing");
    }

    #[test]
    fn a_unit_acpmux_did_not_write_is_foreign_enabled_or_not() {
        for enabled in ["enabled", "disabled", "enabled-runtime", "static"] {
            for u in [
                Units { drop_in: Some("acpmux-update.service"), ..OWN },
                Units { drop_in: Some("acpmux-update.timer"), ..OWN },
                Units { frag: "/etc/systemd/user", ..OWN },
                Units { service: Some(OTHER_TEXT), ..OWN },
                // Only in the manager, from elsewhere.
                Units { frag: "/etc/systemd/user", service: None, timer: None, ..OWN },
                // Only on disk, not loaded, with other text.
                Units { timer: Some(OTHER_TEXT), service: None, loaded: false, ..OWN },
                // acpmux's own files with a drop-in directory beside them.
                Units { drop_in_dir: Some("acpmux-update.timer.d"), ..OWN },
            ] {
                assert_eq!(kind(&probe(Units { enabled, ..u })), "foreign", "{enabled}");
            }
        }
        // Only a drop-in, and no unit at all: --fix would write the unit and
        // systemd would apply the drop-in to it, so nothing is written.
        for u in [
            Units { drop_in: Some("acpmux-update.service"), ..NONE },
            Units { drop_in_dir: Some("acpmux-update.service.d"), ..NONE },
        ] {
            assert_eq!(kind(&probe(u)), "foreign");
        }
    }
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
