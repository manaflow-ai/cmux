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
    /// The probe stops before `checked` (else a systemd host's says it).
    unchecked: bool,
    /// The user's manager does not linger.
    no_linger: bool,
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
            unchecked: false,
            no_linger: false,
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
            assert_eq!(inner, guarded_install_script());
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
        if self.found.contains(&"systemd") && (!self.no_linger || self.installed.get()) {
            words.push(format!("{MARK}linger"));
        }
        if self.found.contains(&"systemd") && !self.unchecked {
            words.push(format!("{MARK}checked"));
        }
        Ok(RemoteOut {
            ok: true,
            // A login banner that tries to answer first is not read.
            stdout: format!(
                "Welcome to box\n{MARK}begin\n{MARK}timer\n{MARK}checked\n{MARK}begin\n{}\n",
                words.join("\n")
            ),
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
    let found = parse(&format!(
        "motd: os=Plan9\n{MARK}begin\n{MARK}os=Linux\n{MARK}systemd\n{MARK}timer\n"
    ));
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
        let r = update(&mac, fix, None);
        assert_eq!((r.step, r.state), (Step::Update, StepState::Ok));
        assert!(r.detail.starts_with("a Mac:"), "{r:?}");

        let cloud = Host::new(&["os=Linux", "cloud", "systemd"]);
        let r = update(&cloud, fix, None);
        assert_eq!(r.state, StepState::Ok);
        assert!(r.detail.contains("cmux Cloud VM"), "{r:?}");

        let timer = Host::new(&["os=Linux", "systemd", "timer"]);
        let r = update(&timer, fix, None);
        assert_eq!(r.state, StepState::Ok);
        assert!(r.detail.contains("every 15 minutes"), "{r:?}");

        let off = Host::new(&["os=Linux", "off", "systemd"]);
        let r = update(&off, fix, None);
        assert_eq!(r.state, StepState::Skip, "turned off by the person: left off");
        assert!(r.fix.as_deref().unwrap().contains("Remove ~/.acpmux/no-auto-update"), "{r:?}");

        let no_systemd = Host::new(&["os=Linux"]);
        let r = update(&no_systemd, fix, None);
        assert_eq!(r.state, StepState::Warn);
        assert!(r.detail.contains("no user systemd"), "{r:?}");

        // Turned off is turned off on a Mac and a Cloud VM too.
        for os in [&["os=Darwin", "off"][..], &["os=Linux", "cloud", "off", "systemd"]] {
            let host = Host::new(os);
            assert_eq!(update(&host, fix, None).state, StepState::Skip, "{os:?}");
        }

        for host in [mac, cloud, timer, off, no_systemd] {
            assert!(host.fenced.borrow().is_empty(), "nothing installed");
        }
    }
}

#[test]
fn doctor_reports_a_missing_timer_and_changes_nothing() {
    let host = Host::new(&["os=Linux", "systemd"]);
    let r = update(&host, false, None);
    assert_eq!(r.state, StepState::Warn, "a host without the timer still works");
    assert!(r.fix.as_deref().unwrap().contains("--fix"), "{r:?}");
    assert!(host.fenced.borrow().is_empty());
    let report = crate::cli::host_steps::Report::new("box", "leo@box.tail", vec![r]);
    assert!(report.ok);
}

#[test]
fn enroll_installs_the_timer_under_the_update_lock() {
    let host = Host::new(&["os=Linux", "systemd"]);
    let r = update(&host, true, None);
    assert_eq!((r.step, r.state), (Step::Update, StepState::Fixed), "{r:?}");
    assert!(r.detail.starts_with("installed acpmux-update.timer"), "{r:?}");
    assert_eq!(host.fenced.borrow().len(), 1, "one install, fenced for the lease");
    assert_eq!(serde_json::to_value(&r).unwrap()["step"], "update");
}

#[test]
fn a_unit_someone_else_wrote_is_left_alone_and_said() {
    let mut host = Host::new(&["os=Linux", "systemd"]);
    host.install_out = "ACPMUX_AUTO_UPDATE_OFF=/etc/systemd/user/acpmux-update.timer is a unit acpmux did not write, so this host does not update itself: remove it, then run host update again";
    let r = update(&host, true, None);
    assert_eq!(r.state, StepState::Warn);
    assert!(
        r.detail
            .starts_with("/etc/systemd/user/acpmux-update.timer is a unit acpmux did not write"),
        "{r:?}"
    );
}

/// A drop-in that shows up between the probe and the install: the probe
/// run again under the lock finds it, and nothing is written.
#[test]
fn a_drop_in_found_under_the_lock_stops_the_install() {
    let mut host = Host::new(&["os=Linux", "systemd"]);
    host.install_out = "ACPMUX_AU=begin\nACPMUX_AU=foreign";
    let r = update(&host, true, None);
    assert_eq!(r.state, StepState::Warn, "{r:?}");
    assert!(r.detail.contains("acpmux did not write"), "{r:?}");
    assert_eq!(host.fenced.borrow().len(), 1);
    // XDG_CONFIG_HOME set in between: the same.
    let mut host = Host::new(&["os=Linux", "systemd"]);
    host.install_out = "ACPMUX_AU=begin\nACPMUX_AU=xdg";
    let r = update(&host, true, None);
    assert!(r.detail.starts_with("this host sets XDG_CONFIG_HOME"), "{r:?}");
    let script = guarded_install_script();
    assert!(script.starts_with("au_probe() {"), "{script}");
    assert!(script.contains(&hosts::install_script()), "{script}");
}

/// A timer on a manager that does not linger stops at logout: said, and
/// `--fix` asks for lingering in the guarded install.
#[test]
fn a_manager_that_does_not_linger_is_said() {
    let mut host = Host::new(&["os=Linux", "systemd", "timer"]);
    host.no_linger = true;
    let r = update(&host, false, None);
    assert_eq!(r.state, StepState::Warn, "{r:?}");
    assert!(r.detail.contains("does not linger"), "{r:?}");
    assert!(r.fix.as_deref().unwrap().contains("--fix to turn on lingering"), "{r:?}");
    let mut host = Host::new(&["os=Linux", "systemd"]);
    host.install_out = "ACPMUX_AU=begin\nACPMUX_AU=nolinger";
    let r = update(&host, true, None);
    assert!(r.detail.contains("enable-linger was refused"), "{r:?}");
    assert!(guarded_install_script().contains(hosts::SYSTEMD_LINGERING));
    // A running timer that does not linger: --fix asks for lingering under
    // the lock (the guarded install), then reads it back.
    let mut host = Host::new(&["os=Linux", "systemd", "timer"]);
    host.no_linger = true;
    let r = update(&host, true, None);
    assert_eq!(r.state, StepState::Fixed, "{r:?}");
    assert_eq!(host.fenced.borrow().len(), 1);
}

/// acpmux-update.timer is installed on Linux only, and not where the Cloud
/// VM mark cannot be read.
#[test]
fn only_a_known_linux_host_gets_the_timer() {
    for found in
        [&["systemd"][..], &["os=FreeBSD", "systemd"], &["os=Linux", "cloud-unknown", "systemd"]]
    {
        let host = Host::new(found);
        let r = update(&host, true, None);
        assert_eq!(r.state, StepState::Warn, "{found:?}: {r:?}");
        assert!(r.detail.contains("left as it is"), "{r:?}");
        assert!(host.fenced.borrow().is_empty());
    }
}

/// What the probe prints counts after its own `begin`, and `checked` only
/// as its last line.
#[test]
fn the_probes_words_are_framed() {
    let found = parse("ACPMUX_AU=timer\nACPMUX_AU=checked\nACPMUX_AU=begin\nACPMUX_AU=systemd\n");
    assert!(found.systemd && !found.timer && !found.checked, "{found:?}");
    let cut = parse("ACPMUX_AU=begin\nACPMUX_AU=systemd\nACPMUX_AU=checked\nACPMUX_AU=timer\n");
    assert!(cut.timer && !cut.checked, "{cut:?}");
    assert_eq!(parse("ACPMUX_AU=systemd\nACPMUX_AU=checked\n"), Found::default());
    // A timer the probe saw but did not close is not counted.
    let mut host = Host::new(&["os=Linux", "systemd", "timer"]);
    host.unchecked = true;
    assert_eq!(update(&host, false, None).state, StepState::Warn);
}

/// A probe cut short (no `checked`), first or under the lock: nothing is
/// written.
#[test]
fn a_probe_that_did_not_read_to_the_end_installs_nothing() {
    let mut host = Host::new(&["os=Linux", "systemd"]);
    host.unchecked = true;
    let r = update(&host, true, None);
    assert_eq!(r.state, StepState::Warn, "{r:?}");
    assert!(r.detail.starts_with("could not read acpmux-update's units"), "{r:?}");
    assert!(host.fenced.borrow().is_empty());
    let mut host = Host::new(&["os=Linux", "systemd"]);
    host.install_out = "ACPMUX_AU=begin\nACPMUX_AU=unchecked";
    let r = update(&host, true, None);
    assert!(r.detail.starts_with("could not read acpmux-update's units"), "{r:?}");
}

#[test]
fn another_xdg_config_home_is_said_and_nothing_is_written() {
    for fix in [false, true] {
        let host = Host::new(&["os=Linux", "systemd", "xdg"]);
        let r = update(&host, fix, None);
        assert_eq!(r.state, StepState::Warn, "{r:?}");
        assert!(r.detail.starts_with("this host sets XDG_CONFIG_HOME"), "{r:?}");
        assert!(host.fenced.borrow().is_empty());
    }
}

#[test]
fn an_enabled_timer_acpmux_did_not_write_is_not_counted_or_replaced() {
    for fix in [false, true] {
        let host = Host::new(&["os=Linux", "systemd", "foreign"]);
        let r = update(&host, fix, None);
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
    let r = update(&host, false, None);
    assert_eq!(r.state, StepState::Warn, "{r:?}");
    assert!(r.detail.contains("off or stopped"), "{r:?}");
    assert!(r.fix.as_deref().unwrap().contains("--fix to start"), "{r:?}");
    assert!(host.fenced.borrow().is_empty());

    let r = update(&host, true, None);
    assert_eq!(r.state, StepState::Fixed, "{r:?}");
    assert_eq!(host.fenced.borrow().len(), 1);

    let mut host = Host::new(&["os=Linux", "systemd"]);
    host.starts = false;
    let r = update(&host, true, None);
    assert_eq!(r.state, StepState::Warn, "installed but not running: {r:?}");
    assert!(r.detail.contains("not running"), "{r:?}");
}

/// The real probe, run by `sh` against a fake `systemctl` in a scratch home (unix: modes,
/// symlinks and a shell).
#[cfg(unix)]
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
        /// The manager lists a drop-in for every unit of the type (Fedora's
        /// `service.d/10-timeout-abort.conf`) on both units: `system` (a
        /// path this user cannot change), `home` (one in
        /// ~/.config/systemd/user), `dotdot` (that one, spelled from /usr).
        type_drop_in: Option<&'static str>,
        /// Beside that type-wide drop-in in ~/.config/systemd/user, a
        /// dot-file (`dot`) or a link that points nowhere (`dangling`).
        hidden_drop_in: Option<&'static str>,
        /// The `analyzed_drop_in_dir`, its files and its unit path are
        /// read-only to this user (who still owns them).
        read_only: bool,
        /// `XDG_CONFIG_HOME` in the probe's shell (`home`: ~/.config).
        xdg: Option<&'static str>,
        /// `XDG_CONFIG_HOME` in the user manager's environment.
        manager_xdg: Option<&'static str>,
        /// A drop-in directory in a unit path only the running manager names
        /// (`UnitPath`); `fails`: reading `UnitPath` fails.
        manager_drop_in_dir: Option<&'static str>,
        /// That unit path, under the test's root (it may hold spaces).
        manager_dir: &'static str,
        /// The user manager does not answer (`show-environment` fails).
        no_manager: bool,
        /// `systemd-analyze` fails.
        no_analyze: bool,
        /// A unit file `acpmux-update.service` of another's text in this
        /// directory under $HOME (another unit path).
        full_unit_in: Option<&'static str>,
        /// `sed` and `tr` fail (the probe uses neither).
        no_sed: bool,
        /// ~/.config/systemd/user/acpmux-update.service is a FIFO.
        fifo: bool,
        /// A dangling symlink of this unit's name in ~/.config/systemd/user.
        dangling: Option<&'static str>,
        /// `Linger` is not yes, and `enable-linger` is refused.
        no_linger: bool,
        /// The analyzed unit path (`unit`), the directory above it
        /// (`above`), or ~/.acpmux holding `no-auto-update` (`home`) cannot
        /// be searched.
        sealed: Option<&'static str>,
        /// The files in ~/.config/systemd/user: acpmux's text, another's, or none.
        service: Option<&'static str>,
        timer: Option<&'static str>,
        /// A drop-in directory on disk, under ~/.config/systemd/user.
        drop_in_dir: Option<&'static str>,
        /// A drop-in directory in a unit path only `systemd-analyze` names.
        analyzed_drop_in_dir: Option<&'static str>,
    }

    const OWN: Units = Units {
        enabled: "enabled",
        active: true,
        loaded: true,
        frag: "own",
        drop_in: None,
        type_drop_in: None,
        hidden_drop_in: None,
        read_only: false,
        xdg: None,
        manager_xdg: None,
        manager_drop_in_dir: None,
        manager_dir: "manager-units",
        no_manager: false,
        no_analyze: false,
        full_unit_in: None,
        no_sed: false,
        fifo: false,
        dangling: None,
        no_linger: false,
        sealed: None,
        service: Some(hosts::UPDATE_SERVICE),
        timer: Some(hosts::UPDATE_TIMER),
        drop_in_dir: None,
        analyzed_drop_in_dir: None,
    };
    const NONE: Units = Units {
        enabled: "",
        active: false,
        loaded: false,
        frag: "",
        drop_in: None,
        type_drop_in: None,
        hidden_drop_in: None,
        read_only: false,
        xdg: None,
        manager_xdg: None,
        manager_drop_in_dir: None,
        manager_dir: "manager-units",
        no_manager: false,
        no_analyze: false,
        full_unit_in: None,
        no_sed: false,
        fifo: false,
        dangling: None,
        no_linger: false,
        sealed: None,
        service: None,
        timer: None,
        drop_in_dir: None,
        analyzed_drop_in_dir: None,
    };
    const OTHER_TEXT: &str = "[Service]\nExecStart=/usr/bin/true\n";

    fn probe(u: Units) -> Found {
        parse(&run(u, &probe_script()).0)
    }

    /// Runs `script` by `sh` on a host with `u`: its output, and whether
    /// acpmux's units are in ~/.config/systemd/user afterwards.
    fn run(u: Units, script: &str) -> (String, bool) {
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
        let extra = root.join("extra-units");
        for (dir, name) in [(&units, u.drop_in_dir), (&extra, u.analyzed_drop_in_dir)] {
            if let Some(name) = name {
                fs::create_dir_all(dir.join(name)).unwrap();
                fs::write(dir.join(name).join("o.conf"), OTHER_TEXT).unwrap();
            }
        }
        let type_dir = match u.type_drop_in {
            Some("system") => "/usr/lib/systemd/user".to_owned(),
            Some(how) => {
                for kind in ["service.d", "timer.d"] {
                    fs::create_dir_all(units.join(kind)).unwrap();
                    fs::write(units.join(kind).join("10-timeout-abort.conf"), OTHER_TEXT).unwrap();
                    match u.hidden_drop_in {
                        Some("dot") => {
                            fs::write(units.join(kind).join(".override.conf"), OTHER_TEXT).unwrap()
                        }
                        Some(_) => std::os::unix::fs::symlink(
                            root.join("nowhere.conf"),
                            units.join(kind).join("zz.conf"),
                        )
                        .unwrap(),
                        None => {}
                    }
                }
                let path = units.display().to_string();
                if how == "dotdot" { format!("/usr/..{path}") } else { path }
            }
            None => String::new(),
        };
        let mode = |path: &Path, mode| fs::set_permissions(path, fs::Permissions::from_mode(mode));
        let read_only = |m: u32, d: u32| {
            if let (true, Some(name)) = (u.read_only, u.analyzed_drop_in_dir) {
                mode(&extra.join(name).join("o.conf"), m).unwrap();
                mode(&extra.join(name), d).unwrap();
                mode(&extra, d).unwrap();
            }
        };
        read_only(0o444, 0o555);
        let manager = root.join(u.manager_dir);
        if u.no_sed {
            for tool in ["sed", "tr"] {
                crate::test_exec::write_executable(bin.join(tool), "#!/bin/sh\nexit 127\n");
            }
        }
        let loginctl = bin.join("loginctl");
        let linger = if u.no_linger {
            "echo no;; enable-linger) exit 1"
        } else {
            "echo yes;; enable-linger) exit 0"
        };
        crate::test_exec::write_executable(
            &loginctl,
            format!("#!/bin/sh\ncase \"$1\" in show-user) {linger};; esac\n"),
        );
        if let Some(name) = u.dangling {
            std::os::unix::fs::symlink(root.join("nowhere"), units.join(name)).unwrap();
        }
        if u.fifo {
            let fifo = units.join("acpmux-update.service");
            assert!(Command::new("mkfifo").arg(&fifo).status().unwrap().success());
        }
        if let Some(dir) = u.full_unit_in {
            fs::create_dir_all(home.join(dir)).unwrap();
            fs::write(home.join(dir).join("acpmux-update.service"), OTHER_TEXT).unwrap();
        }
        // A sibling a glob of the manager's path would match instead.
        fs::create_dir_all(root.join("manager-unitsa")).unwrap();
        let unit_path = match u.manager_drop_in_dir {
            Some("fails") => "FAIL".to_owned(),
            Some("empty") => String::new(),
            Some(name) => {
                fs::create_dir_all(manager.join(name)).unwrap();
                fs::write(manager.join(name).join("o.conf"), OTHER_TEXT).unwrap();
                manager.display().to_string()
            }
            None => extra.display().to_string(),
        };
        let analyze = bin.join("systemd-analyze");
        let listed = match u.sealed {
            Some("unit") => format!("{}\n{}", extra.display(), extra.join("sealed").display()),
            Some("home") => extra.display().to_string(),
            Some(_) => {
                format!("{}\n{}", extra.display(), extra.join("above/inner/units").display())
            }
            None => extra.display().to_string(),
        };
        let analyzed = if u.no_analyze {
            "exit 1".to_owned()
        } else {
            format!("printf '%s\\n' '{}'", listed.replace('\n', "' '"))
        };
        crate::test_exec::write_executable(&analyze, format!("#!/bin/sh\n{analyzed}\n"));
        let frag = if u.frag == "own" { units.display().to_string() } else { u.frag.into() };
        let fake = format!(
            r#"#!/bin/sh
[ "$1" = --user ] || exit 2; shift
case "$1" in
show-environment) [ {no_manager} = 0 ] || exit 1; [ -z "{manager_xdg}" ] || echo "XDG_CONFIG_HOME={manager_xdg}"; exit 0 ;;
is-enabled) echo "{enabled}" ;;
is-active) exit {active} ;;
show) [ "$2" = -p ] && [ "$3" = UnitPath ] && {{ [ "{unit_path}" = FAIL ] && exit 1; echo "{unit_path}"; exit 0; }}
  case "$4" in
  LoadState) echo {load} ;;
  FragmentPath) [ {load} = loaded ] && echo "{frag}/$2" || echo ;;
  DropInPaths) d=; [ -z "{type_dir}" ] || d="{type_dir}/${{2##*.}}.d/10-timeout-abort.conf"
    [ "$2" = "{drop_in}" ] && d="$d /x/$2.d/o.conf"; echo $d ;;
  esac ;;
*) exit 2 ;;
esac
"#,
            enabled = u.enabled,
            active = if u.active { 0 } else { 3 },
            load = if u.loaded { "loaded" } else { "not-found" },
            drop_in = u.drop_in.unwrap_or("-"),
            type_dir = type_dir,
            manager_xdg = u.manager_xdg.unwrap_or(""),
            no_manager = u8::from(u.no_manager),
            unit_path = unit_path,
        );
        let systemctl = bin.join("systemctl");
        crate::test_exec::write_executable(&systemctl, fake);
        let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
        let mut sh = Command::new("sh");
        sh.arg("-c").arg(script).env("HOME", &home).env("PATH", path).env_remove("XDG_CONFIG_HOME");
        match u.xdg {
            Some("home") => sh.env("XDG_CONFIG_HOME", home.join(".config")),
            Some(other) => sh.env("XDG_CONFIG_HOME", other),
            None => &mut sh,
        };
        let sealed = match u.sealed {
            Some("unit") => Some(extra.join("sealed")),
            Some("home") => Some(home.join(".acpmux")),
            Some(_) => Some(extra.join("above")),
            None => None,
        };
        if let Some(dir) = &sealed {
            fs::create_dir_all(dir.join("inner")).unwrap();
            fs::write(dir.join("no-auto-update"), "").unwrap();
            mode(dir, 0o000).unwrap();
        }
        let out = sh.output().unwrap();
        if let Some(dir) = &sealed {
            mode(dir, 0o755).unwrap();
        }
        read_only(0o644, 0o755);
        let service = units.join("acpmux-update.service");
        let written =
            u.service.is_none() && fs::symlink_metadata(&service).is_ok_and(|m| m.is_file());
        fs::remove_dir_all(&root).unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        (String::from_utf8_lossy(&out.stdout).into_owned(), written)
    }

    fn kind(found: &Found) -> &'static str {
        assert!(found.systemd && found.checked, "{found:?}");
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
    fn a_drop_in_for_every_service_counts_unless_the_system_ships_it() {
        // The distribution's, as the manager lists it: still acpmux's own,
        // running or stopped (so --fix starts it).
        let system = Some("system");
        assert_eq!(kind(&probe(Units { type_drop_in: system, ..OWN })), "timer");
        assert_eq!(kind(&probe(Units { type_drop_in: system, active: false, ..OWN })), "stopped");
        // Beside one for this unit, that one still makes it foreign.
        let both = Units { type_drop_in: system, drop_in: Some("acpmux-update.timer"), ..OWN };
        assert_eq!(kind(&probe(both)), "foreign");
        // One this user can change (the person, or anything running as them,
        // wrote it) would run with acpmux's service: foreign, listed by the
        // manager (also by a path that looks like the system's) or only on
        // disk, with or without the units.
        for u in [OWN, NONE] {
            for found in [
                Units { type_drop_in: Some("home"), ..u },
                Units { type_drop_in: Some("dotdot"), ..u },
                Units { drop_in_dir: Some("service.d"), ..u },
                Units { analyzed_drop_in_dir: Some("timer.d"), ..u },
                // Theirs though read-only: they can make it writable again.
                Units { analyzed_drop_in_dir: Some("timer.d"), read_only: true, ..u },
            ] {
                assert_eq!(kind(&probe(found)), "foreign");
            }
        }
    }

    /// In a type-wide drop-in directory this user cannot change, a file they
    /// can (a dot-file too), or a link that points nowhere, is foreign. The
    /// test's user owns every file it makes, so here `au_mine` says yes only
    /// for the dot-file.
    #[test]
    fn a_hidden_or_dangling_type_wide_drop_in_is_foreign() {
        let theirs =
            r#"au_mine() { case "${1##*/}" in .override.conf) true ;; *) false ;; esac; }"#;
        let ours =
            probe_script().lines().find(|l| l.starts_with("au_mine() {")).unwrap().to_owned();
        let script = probe_script().replace(&ours, theirs);
        assert_ne!(script, probe_script());
        let found = |u: Units| parse(&run(u, &script).0);
        let system = Units { type_drop_in: Some("home"), ..OWN };
        assert_eq!(kind(&found(system)), "timer");
        for hidden in ["dot", "dangling"] {
            for u in [OWN, NONE] {
                let u = Units { type_drop_in: Some("home"), hidden_drop_in: Some(hidden), ..u };
                assert_eq!(kind(&found(u)), "foreign", "{hidden}");
            }
        }
    }

    #[test]
    fn another_xdg_config_home_is_read_from_the_shell_and_the_manager() {
        assert!(probe(Units { xdg: Some("/srv/leo-config"), ..NONE }).xdg);
        assert!(probe(Units { manager_xdg: Some("/srv/leo-config"), ..NONE }).xdg);
        assert!(!probe(Units { xdg: Some("home"), ..NONE }).xdg);
        assert!(!probe(NONE).xdg);
    }

    /// The running manager reads units from a path this shell's
    /// `systemd-analyze` does not name: a drop-in there, for a unit not
    /// written yet, is found; and a manager that cannot say its paths
    /// counts as one with a drop-in.
    #[test]
    fn the_running_managers_unit_paths_are_read() {
        for u in [OWN, NONE] {
            let there = Units { manager_drop_in_dir: Some("acpmux-update.service.d"), ..u };
            assert_eq!(kind(&probe(there)), "foreign");
            let typewide = Units { manager_drop_in_dir: Some("service.d"), ..u };
            assert_eq!(kind(&probe(typewide)), "foreign");
        }
        for u in [OWN, NONE] {
            // A path with a space (`systemctl show` prints the list
            // space-separated): a piece that is not absolute, or two that
            // join into a path there, is not read as two paths.
            for dir in ["manager units", "manager /units"] {
                let spaced = Units {
                    manager_drop_in_dir: Some("acpmux-update.service.d"),
                    manager_dir: dir,
                    ..u
                };
                // Foreign, or (a relative piece has no directory to
                // search) not read at all: either way nothing is installed.
                let found = probe(spaced);
                assert!(found.foreign || !found.checked, "{dir}: {found:?}");
            }
        }
        let (out, written) = run(
            Units {
                manager_drop_in_dir: Some("acpmux-update.service.d"),
                manager_dir: "manager /units",
                ..NONE
            },
            &guarded_install_script(),
        );
        assert!(parse(&out).foreign && !written, "{out}");
        // A path a glob would match a sibling of is read as it is.
        for u in [OWN, NONE] {
            let glob = Units {
                manager_drop_in_dir: Some("acpmux-update.service.d"),
                manager_dir: "manager-units[ab]",
                ..u
            };
            assert_eq!(kind(&probe(glob)), "foreign");
        }
    }

    /// acpmux's own units, loaded, and another `acpmux-update.service` in a
    /// unit path systemd would load first after a reload (`enable` reloads):
    /// foreign, and the install writes and enables nothing.
    #[test]
    fn a_unit_file_in_another_unit_path_is_foreign() {
        for u in [OWN, Units { active: false, ..OWN }, NONE] {
            for dir in [".config/systemd/user.control", ".local/share/systemd/user"] {
                assert_eq!(
                    kind(&probe(Units { full_unit_in: Some(dir), ..u })),
                    "foreign",
                    "{dir}"
                );
            }
        }
        let control = Some(".config/systemd/user.control");
        let (out, written) =
            run(Units { full_unit_in: control, ..NONE }, &guarded_install_script());
        assert!(parse(&out).foreign && !written, "{out}");
    }

    /// The probe needs neither `sed` nor `tr`: the manager's XDG_CONFIG_HOME
    /// and a drop-in only its UnitPath names are still found.
    #[test]
    fn the_probe_runs_without_sed_or_tr() {
        assert!(probe(Units { no_sed: true, manager_xdg: Some("/srv/leo-config"), ..NONE }).xdg);
        let there =
            Units { no_sed: true, manager_drop_in_dir: Some("acpmux-update.service.d"), ..NONE };
        assert_eq!(kind(&probe(there)), "foreign");
        assert_eq!(kind(&probe(Units { no_sed: true, ..OWN })), "timer");
    }

    /// The Cloud VM mark's directory is there but cannot be searched: the
    /// probe says so (run with the mark moved under the test's root).
    #[test]
    fn an_unreadable_cloud_mark_directory_is_said() {
        let dir = std::env::temp_dir().join(format!("acpmux-cloud-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o000)).unwrap();
        let script = probe_script().replace("/etc/cmux", &dir.display().to_string());
        let found = parse(&run(NONE, &script).0);
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        fs::remove_dir_all(&dir).unwrap();
        assert!(found.cloud_unknown && !found.cloud, "{found:?}");
        assert!(probe_script().contains("[ -e /etc/cmux ] && [ ! -x /etc/cmux ]"));
    }

    /// The Cloud VM mark is read through `hosts::cloud_vm_check`, so a Cloud VM
    /// with no acpmux.service of acpmux's own is `cloud` (cmux moves it) and
    /// one whose daemon is that unit's gets the timer as any Linux host does
    /// (a fleet lane host, 2026-10-30). The check itself: `host_update_tests.rs`.
    #[test]
    fn a_cloud_vm_is_said_through_the_shared_check() {
        let dir = std::env::temp_dir().join(format!("acpmux-cloud-mark-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("vm-kind"), "team\n").unwrap();
        let script = probe_script().replace("/etc/cmux", &dir.display().to_string());
        let found = parse(&run(NONE, &script).0);
        fs::remove_dir_all(&dir).unwrap();
        assert!(found.cloud && !found.cloud_unknown, "{found:?}");
        assert!(probe_script().contains(&hosts::cloud_vm_check()));
        assert!(probe_script().contains("if [ -n \"$acpmux_cloud\" ]; then echo ACPMUX_AU=cloud"));
    }

    /// A unit that is not a regular file (a FIFO, which `cmp` would wait on
    /// for ever) is foreign, and read without blocking.
    #[test]
    fn a_unit_that_is_not_a_regular_file_is_foreign() {
        assert_eq!(kind(&probe(Units { fifo: true, service: None, ..OWN })), "foreign");
    }

    /// A unit path this user cannot search, or one under a directory they
    /// cannot search: what is in it is not known, so nothing is installed.
    #[test]
    fn a_unit_path_that_cannot_be_searched_is_never_checked() {
        for sealed in ["unit", "above"] {
            for u in [OWN, NONE] {
                let found = probe(Units { sealed: Some(sealed), ..u });
                assert!(found.systemd && !found.checked, "{sealed}: {found:?}");
            }
            let (out, written) =
                run(Units { sealed: Some(sealed), ..NONE }, &guarded_install_script());
            assert!(parse(&out).unchecked && !written, "{sealed}: {out}");
        }
    }

    /// ~/.acpmux cannot be searched, so whether it holds `no-auto-update` is
    /// not known: never checked, and the install writes nothing.
    #[test]
    fn an_unreadable_off_mark_is_never_checked() {
        for u in [OWN, NONE] {
            let found = probe(Units { sealed: Some("home"), ..u });
            assert!(found.systemd && !found.checked && !found.off, "{found:?}");
        }
        let (out, written) = run(Units { sealed: Some("home"), ..NONE }, &guarded_install_script());
        assert!(parse(&out).unchecked && !written, "{out}");
    }

    /// Lingering is read; the guarded install asks for it, and writes nothing
    /// when it is refused.
    #[test]
    fn the_install_needs_a_lingering_manager() {
        assert!(probe(OWN).linger);
        assert!(!probe(Units { no_linger: true, ..OWN }).linger);
        let (out, written) = run(Units { no_linger: true, ..NONE }, &guarded_install_script());
        assert!(parse(&out).nolinger && !written, "{out}");
    }

    /// A symlink of a unit's name that points nowhere (`-e` is false for it):
    /// foreign, and the install writes nothing over it.
    #[test]
    fn a_dangling_unit_link_is_foreign() {
        for name in ["acpmux-update.service", "acpmux-update.timer"] {
            for u in [NONE, Units { loaded: false, service: None, timer: None, ..OWN }] {
                assert_eq!(kind(&probe(Units { dangling: Some(name), ..u })), "foreign", "{name}");
            }
            let (out, written) =
                run(Units { dangling: Some(name), ..NONE }, &guarded_install_script());
            assert!(parse(&out).foreign && !written, "{name}: {out}");
        }
    }

    /// The manager's `UnitPath` is space-separated: a path with spaces in it
    /// is still found (any run of pieces that exists counts), and a list with
    /// two spaces in a row is not read.
    #[test]
    fn a_manager_path_with_spaces_is_not_lost() {
        for u in [OWN, NONE] {
            let three = Units {
                manager_drop_in_dir: Some("acpmux-update.service.d"),
                manager_dir: "manager /one /two",
                ..u
            };
            assert_eq!(kind(&probe(three)), "foreign");
            let doubled = Units {
                manager_drop_in_dir: Some("acpmux-update.service.d"),
                manager_dir: "manager  /units",
                ..u
            };
            assert!(!probe(doubled).checked);
        }
        let doubled = Units {
            manager_drop_in_dir: Some("acpmux-update.service.d"),
            manager_dir: "manager  /units",
            ..NONE
        };
        let (out, written) = run(doubled, &guarded_install_script());
        assert!(parse(&out).unchecked && !written, "{out}");
    }

    /// A unit path list the manager or `systemd-analyze` does not give (it
    /// fails, or is empty): the probe is not `checked`, so nothing is
    /// installed, also under the lock.
    #[test]
    fn an_unread_unit_path_list_is_never_checked() {
        for u in [OWN, NONE] {
            for broken in [
                Units { manager_drop_in_dir: Some("fails"), ..u },
                Units { manager_drop_in_dir: Some("empty"), ..u },
                Units { no_analyze: true, ..u },
            ] {
                let found = probe(broken);
                assert!(found.systemd && !found.checked, "{found:?}");
            }
        }
        let (out, written) = run(Units { no_analyze: true, ..NONE }, &guarded_install_script());
        assert!(parse(&out).unchecked && !written, "{out}");
    }

    /// A user manager that does not answer, under the lock: nothing is read,
    /// so nothing is written.
    #[test]
    fn the_install_writes_nothing_when_the_manager_does_not_answer() {
        let (out, written) = run(Units { no_manager: true, ..NONE }, &guarded_install_script());
        assert!(parse(&out).unchecked, "{out}");
        assert!(!written, "no unit written");
        assert!(!probe(Units { no_manager: true, ..OWN }).checked);
    }

    /// The probe again under the lock also refuses another XDG_CONFIG_HOME.
    #[test]
    fn the_install_writes_nothing_under_another_xdg_config_home() {
        let (out, written) =
            run(Units { manager_xdg: Some("/srv/leo-config"), ..NONE }, &guarded_install_script());
        assert!(parse(&out).xdg, "{out}");
        assert!(!written, "no unit written");
    }

    /// The install runs the probe again under the lock: a drop-in there
    /// stops it before any unit is written.
    #[test]
    fn the_install_writes_nothing_beside_a_drop_in() {
        let (out, written) =
            run(Units { drop_in_dir: Some("service.d"), ..NONE }, &guarded_install_script());
        assert!(parse(&out).foreign, "{out}");
        assert!(!written, "no unit written");
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
                // acpmux's own files with a drop-in directory beside them,
                // by name, by its dash prefix, or in a path systemd names.
                Units { drop_in_dir: Some("acpmux-update.timer.d"), ..OWN },
                Units { drop_in_dir: Some("acpmux-.service.d"), ..OWN },
                Units { analyzed_drop_in_dir: Some("acpmux-update.service.d"), ..OWN },
            ] {
                assert_eq!(kind(&probe(Units { enabled, ..u })), "foreign", "{enabled}");
            }
        }
        // Only a drop-in, and no unit at all: --fix would write the unit and
        // systemd would apply the drop-in to it, so nothing is written.
        for u in [
            Units { drop_in: Some("acpmux-update.service"), ..NONE },
            Units { drop_in_dir: Some("acpmux-update.service.d"), ..NONE },
            Units { analyzed_drop_in_dir: Some("acpmux-.timer.d"), ..NONE },
        ] {
            assert_eq!(kind(&probe(u)), "foreign");
        }
    }
}

#[test]
fn cmux_own_acpmux_never_gets_the_timer() {
    // The app's install or a cmux session daemon: the timer would run a
    // standalone acpmux's updater, which is not what runs there.
    for fix in [false, true] {
        for found in [&["os=Linux", "systemd"][..], &["os=Linux", "systemd", "stopped"]] {
            let host = Host::new(found);
            let r = update(&host, fix, Some("/home/leo/.local/bin/cmux-tui"));
            assert_eq!(r.state, StepState::Skip, "{r:?}");
            assert!(
                r.detail.starts_with("cmux's own acpmux runs here (/home/leo/.local/bin/cmux-tui)"),
                "{r:?}"
            );
            assert!(host.fenced.borrow().is_empty(), "nothing installed");
        }
    }
}

#[test]
fn another_update_holding_the_lock_is_a_warning() {
    let mut host = Host::new(&["os=Linux", "systemd"]);
    host.locked = true;
    let r = update(&host, true, None);
    assert_eq!(r.state, StepState::Warn);
    assert!(r.detail.contains("another update of leo@box.tail is running"), "{r:?}");
    assert!(host.fenced.borrow().is_empty());
}
