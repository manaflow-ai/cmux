//! `acpmux host enroll` and `host doctor` (cli/host_enroll.rs): ssh failure
//! classes, step gating, the home rewrite, the profile mode check, and a
//! doctor that changes nothing without --fix.

use super::*;
use crate::cli::hosts::RemoteOut;
use std::cell::RefCell;

/// A host that answers each script through `answer` (a script fenced for
/// the update lock by the script inside it) and logs every call; `push`
/// only records. Its update lock is free unless `locked`.
struct Fake<F: Fn(&str, Option<&[u8]>) -> RemoteOut> {
    answer: F,
    calls: RefCell<Vec<(String, bool)>>,
    /// The scripts that ran fenced for the update lock.
    fenced: RefCell<Vec<String>>,
    pushes: RefCell<Vec<String>>,
    locked: std::cell::Cell<bool>,
}

impl<F: Fn(&str, Option<&[u8]>) -> RemoteOut> Fake<F> {
    fn new(answer: F) -> Self {
        Self {
            answer,
            calls: RefCell::default(),
            fenced: RefCell::default(),
            pushes: RefCell::default(),
            locked: Default::default(),
        }
    }
}

impl<F: Fn(&str, Option<&[u8]>) -> RemoteOut> Remote for Fake<F> {
    fn host(&self) -> &str {
        "leo@box.tail"
    }
    fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut> {
        let script = match crate::cli::hosts::unfence(script) {
            Some(inner) => {
                self.fenced.borrow_mut().push(inner.to_owned());
                inner
            }
            None => script,
        };
        self.calls.borrow_mut().push((script.to_owned(), stdin.is_some()));
        Ok((self.answer)(script, stdin))
    }
    fn push(&self, _local: &Path, remote: &str) -> Result<()> {
        self.pushes.borrow_mut().push(remote.to_owned());
        Ok(())
    }
    /// The host's update lock (`hosts::lock_updates`): free, or `locked`.
    fn spawn(&self, _script: &str) -> Result<std::process::Child> {
        use std::process::{Command, Stdio};
        let answer = if self.locked.get() {
            "echo ACPMUX_UPDATE_RUNNING"
        } else {
            "echo ACPMUX_UPDATE_LOCKED; exec cat >/dev/null"
        };
        let child = Command::new("sh")
            .args(["-c", answer])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()?;
        Ok(child)
    }
}

fn out(stdout: impl Into<String>) -> RemoteOut {
    RemoteOut { ok: true, stdout: stdout.into(), stderr: String::new() }
}

fn version(build: &str) -> String {
    format!("bin=acpmux 0.1.0 ({build})\n")
}

const CONFIG: &str = r#"{"websocket":{"listen":"127.0.0.1:47811","token":"t"}}"#;

fn plan(harnesses: &[&str]) -> Plan {
    Plan {
        name: "box".into(),
        host: "leo@box.tail".into(),
        port: Some(47811),
        harnesses: harnesses.iter().map(|s| s.to_string()).collect(),
        remote_binary: DAEMON_BIN.into(),
        reverse: false,
    }
}

/// A local harness folder with profile `id` mentioning the local home.
fn local_with(tag: &str, id: &str, text: &str) -> Local {
    let dir = std::env::temp_dir().join(format!("acpmux-enroll-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(format!("{id}.toml")), text).unwrap();
    Local { harness_dir: Some(dir), home: Some(PathBuf::from("/Users/leo")) }
}

fn states(results: &[StepResult]) -> Vec<(Step, StepState)> {
    results.iter().map(|r| (r.step, r.state)).collect()
}

#[test]
fn ssh_stderr_is_classified() {
    let cases = [
        (
            "ssh: Could not resolve hostname nope: nodename nor servname provided, or not known",
            SshFailure::NoRoute,
        ),
        ("ssh: connect to host 10.0.0.9 port 22: No route to host", SshFailure::NoRoute),
        ("ssh: connect to host box port 22: Operation timed out", SshFailure::NoRoute),
        ("ssh: connect to host box port 22: Connection refused", SshFailure::SshOff),
        ("leo@box: Permission denied (publickey,password).", SshFailure::KeyRejected),
        (
            "@@@@@@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n@@@@@@@@@@@\nHost key verification failed.",
            SshFailure::HostKeyChanged,
        ),
        (
            "No ED25519 host key is known for box and you have requested strict checking.\nHost key verification failed.",
            SshFailure::HostKeyChanged,
        ),
        ("kex_exchange_identification: read: Connection reset by peer", SshFailure::Other),
    ];
    for (stderr, want) in cases {
        assert_eq!(SshFailure::of(stderr), want, "{stderr}");
    }
    assert!(SshFailure::KeyRejected.fix("leo@box").contains("ssh-copy-id leo@box"));
    assert!(SshFailure::HostKeyChanged.fix("leo@box").contains("ssh-keygen -R box"));
    let tailnet_fix = SshFailure::NoRoute.fix("leo@huge-blue.tail9.ts.net");
    assert!(tailnet_fix.contains("Tailscale SSH isn't allowed to this machine"));
    assert!(tailnet_fix.contains("\"dst\": [\"huge-blue.tail9.ts.net\"]"));
    assert!(!tailnet_fix.contains("token") && !tailnet_fix.contains("key="));
}

#[test]
fn a_failure_skips_what_depends_on_it() {
    let r = |step, state| StepResult::new(step, state, "");
    // Reach failed: everything after it is skipped, transitively.
    let mut done = vec![r(Step::Reach, StepState::Fail)];
    for step in
        [Step::Install, Step::Daemon, Step::Harness, Step::Peer, Step::PeerBack, Step::Identity]
    {
        let skip = gate(step, &done).expect("skipped");
        assert_eq!(skip.state, StepState::Skip);
        done.push(skip);
    }
    assert_eq!(done[1].detail, "needs reach");
    assert_eq!(done[2].detail, "needs install");
    assert_eq!(done[3].detail, "needs daemon");
    // Install failed: daemon and what needs it skip; identity still runs.
    let done = vec![r(Step::Reach, StepState::Ok), r(Step::Install, StepState::Fail)];
    assert!(gate(Step::Daemon, &done).is_some());
    assert!(gate(Step::Identity, &done).is_none());
    // Fixed and warn pass; a harness not asked for blocks nothing.
    let done = vec![
        r(Step::Reach, StepState::Ok),
        r(Step::Install, StepState::Fixed),
        r(Step::Daemon, StepState::Ok),
        r(Step::Harness, StepState::Skip),
    ];
    assert!(gate(Step::Daemon, &done).is_none());
    assert!(gate(Step::Peer, &done).is_none());
}

#[test]
fn the_local_home_is_rewritten_only_as_a_whole_prefix() {
    let text = "command = \"/Users/leo/bin/agent\"\ncwd = '/Users/leo'\nother = \"/Users/leonard/x\"\nnested = \"/opt/Users/leo/y\"\n";
    assert_eq!(
        rewrite_home(text, "/Users/leo", "/home/leo"),
        "command = \"/home/leo/bin/agent\"\ncwd = '/home/leo'\nother = \"/Users/leonard/x\"\nnested = \"/opt/Users/leo/y\"\n"
    );
    assert_eq!(rewrite_home("x", "", "/home/leo"), "x");
    assert_eq!(rewrite_home("/Users/leo/a", "/Users/leo/", "/home/l"), "/home/l/a");
}

#[test]
fn a_profile_others_can_write_is_refused() {
    assert_eq!(profile_perms("-rw-------  1 501  20  12 Oct 20 12:00 /h/x.toml", "501"), Ok(()));
    assert_eq!(profile_perms("-rw-r--r--@ 1 501  20  12 Oct 20 12:00 /h/x.toml", "501"), Ok(()));
    assert!(profile_perms("-rw-rw-r--  1 501  20  12 Oct 20 12:00 /h/x.toml", "501").is_err());
    assert!(profile_perms("-rw----rw-  1 501  20  12 Oct 20 12:00 /h/x.toml", "501").is_err());
    assert_eq!(
        profile_perms("-rw-------  1 0  0  12 Oct 20 12:00 /h/x.toml", "501"),
        Err("owned by another user")
    );
    assert_eq!(
        profile_perms("drwx------  2 501 20 64 Oct 20 12:00 /h/x.toml", "501"),
        Err("not a regular file")
    );
}

#[test]
fn a_name_defaults_to_the_short_host_and_doctor_finds_peers() {
    assert_eq!(hosts::short_name("leo@huge-blue.tail1234.ts.net"), "huge-blue");
    assert_eq!(hosts::short_name("cmux16"), "cmux16");
    let peers = vec![
        json!({"name": "hb", "url": "ssh://leo@huge-blue.tail:47900"}),
        json!({"name": "web", "url": "ws://10.0.0.2:47811"}),
    ];
    assert_eq!(pick_target(&peers, "hb"), ("hb".into(), "leo@huge-blue.tail".into(), Some(47900)));
    assert_eq!(
        pick_target(&peers, "leo@huge-blue.tail"),
        ("hb".into(), "leo@huge-blue.tail".into(), Some(47900))
    );
    assert_eq!(pick_target(&peers, "web"), ("web".into(), "web".into(), None));
    assert_eq!(pick_target(&peers, "box.lan"), ("box".into(), "box.lan".into(), None));
}

#[test]
fn version_and_platform_parsing() {
    assert_eq!(build_of("acpmux 0.1.0 (abc123 2026-10-20)"), Some("abc123 2026-10-20"));
    assert_eq!(build_of("acpmux 0.1.0"), None);
    assert_eq!(parse_installed("bin=acpmux 1 (a)\n", false), (Some("a".into()), Some("a".into())));
    assert_eq!(parse_installed("bin=cmux acp 1 (a)\ndaemon=\n", true), (Some("a".into()), None));
    assert!(same_platform("Darwin arm64", "macos", "aarch64"));
    assert!(same_platform("Linux x86_64", "linux", "x86_64"));
    assert!(!same_platform("Linux aarch64", "macos", "aarch64"));
    assert!(!same_platform("Darwin x86_64", "macos", "aarch64"));
}

#[test]
fn json_lines_have_the_contract_shape() {
    let step = StepResult::new(Step::Reach, StepState::Fail, "no route").with_fix("check the name");
    let line = step_line(&step);
    assert!(!line.contains('\n'));
    let v: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(
        v,
        json!({"step": "reach", "state": "fail", "detail": "no route", "fix": "check the name"})
    );
    let report = Report::new("box", "leo@box", vec![step]);
    let v: Value = serde_json::from_str(&report_line(&report)).unwrap();
    assert_eq!(v["report"]["name"], "box");
    assert_eq!(v["report"]["host"], "leo@box");
    assert_eq!(v["report"]["ok"], false);
    assert_eq!(v["report"]["steps"][0]["step"], "reach");
    assert!(v["report"]["steps"][0].get("fix").is_some());
}

const LOCAL_BIN: &str = "/home/leo/.local/bin/acpmux";
const APP_BIN: &str = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux";
const APP_EXE: &str = "/Applications/cmux NIGHTLY.app/Contents/MacOS/cmux";
const TUI_BIN: &str = "/home/leo/.local/bin/cmux-tui";

/// What [`probe_script`] prints for these binaries (path, build), with a daemon of
/// `daemon` (build, person key) answering through the first of them.
fn probe_out(bins: &[(&str, &str)], daemon: Option<(&str, bool)>) -> String {
    probe_out_with(bins, daemon, "", Some(false))
}

/// [`probe_out`], with the daemon's status naming its executable `exe` (none
/// when empty) and whether it runs as `cmux-tui acp` (`acp`; None: a daemon
/// too old to say).
fn probe_out_with(
    bins: &[(&str, &str)],
    daemon: Option<(&str, bool)>,
    exe: &str,
    acp: Option<bool>,
) -> String {
    let mut out = String::new();
    for (i, (path, build)) in bins.iter().enumerate() {
        out.push_str(&format!("bin\t{path}\tacpmux 0.1.0 ({build})\n"));
        let status = match daemon.filter(|_| i == 0) {
            Some((b, key)) => {
                let mut v = json!({ "pid": 7, "build": b, "personKey": key });
                if !exe.is_empty() {
                    v["exe"] = json!(exe);
                }
                if let Some(acp) = acp {
                    v["runsAsCmuxTuiAcp"] = json!(acp);
                }
                serde_json::to_string_pretty(&v).unwrap().replace('\n', "")
            }
            None => String::new(),
        };
        out.push_str(&format!("status\t{path}\t{status}\n"));
    }
    format!("{out}\0{CONFIG}")
}

/// A host with these binaries and daemon (its status names its executable
/// `exe`), whose harness folder holds `profile`; any write panics.
fn host_with<'a>(
    bins: &'a [(&'a str, &'a str)],
    daemon: Option<(&'a str, bool)>,
    exe: &'a str,
    profile: &'a str,
) -> Fake<impl Fn(&str, Option<&[u8]>) -> RemoteOut + 'a> {
    host_reporting(bins, daemon, exe, Some(false), profile)
}

/// [`host_with`], its daemon saying `acp` ([`probe_out_with`]).
fn host_reporting<'a>(
    bins: &'a [(&'a str, &'a str)],
    daemon: Option<(&'a str, bool)>,
    exe: &'a str,
    acp: Option<bool>,
    profile: &'a str,
) -> Fake<impl Fn(&str, Option<&[u8]>) -> RemoteOut + 'a> {
    Fake::new(move |script, stdin| {
        assert!(stdin.is_none(), "a write: {script}");
        if script == "true" {
            out("")
        } else if script == probe_script().as_str() {
            out(probe_out_with(bins, daemon, exe, acp))
        } else if script == format!("readlink -f {DAEMON_BIN} 2>/dev/null") {
            // No ~/.local/bin/acpmux link.
            out("")
        } else if script.starts_with("printf 'bin=") {
            let local = bins.iter().find(|(p, _)| *p == LOCAL_BIN);
            out(local.map(|(_, b)| version(b)).unwrap_or_else(|| "bin=\n".into()))
        } else if script.starts_with("printf %s") {
            out("/home/leo")
        } else if script.contains("id -u") {
            out(format!("1000\n-rw------- 1 1000 1000 9 Oct 20 12:00 f\n\0{profile}"))
        } else {
            panic!("unexpected script: {script}")
        }
    })
}

/// No push, no stdin and no command that writes.
fn assert_read_only<F: Fn(&str, Option<&[u8]>) -> RemoteOut>(fake: &Fake<F>) {
    assert!(fake.pushes.borrow().is_empty());
    for (script, stdin) in fake.calls.borrow().iter() {
        assert!(!stdin, "{script}");
        if script == probe_script().as_str() {
            continue;
        }
        for writes in
            ["mv ", "cat >", "ln -s", "launchctl", "daemon start", "chmod", "mkdir", "rm "]
        {
            assert!(!script.contains(writes), "{script}");
        }
    }
}

#[test]
fn the_probe_reads_only_and_parses_what_it_found() {
    for writes in ["mv ", "cat >", "ln ", "launchctl", "daemon start", "chmod", "mkdir", "rm "] {
        assert!(!probe_script().contains(writes), "{writes}");
    }
    let p = parse_probe(&probe_out(&[(APP_BIN, "a"), (LOCAL_BIN, "b")], Some(("a", true))));
    assert_eq!(
        p.bins,
        [(APP_BIN.to_owned(), Some("a".into())), (LOCAL_BIN.to_owned(), Some("b".into()))]
    );
    let run = p.running.as_ref().unwrap();
    assert_eq!(
        (run.via.as_str(), run.pid, run.build.as_deref(), run.person_key),
        (APP_BIN, 7, Some("a"), true)
    );
    assert_eq!(p.config, CONFIG);
    assert_eq!(parse_probe("\0"), Probe::default());
}

#[test]
#[cfg(unix)]
fn the_probe_finds_an_app_with_a_space_in_its_name() {
    let home = std::env::temp_dir().join(format!("acpmux-enroll-probe-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let bin = home.join(".local/bin/acpmux");
    std::fs::create_dir_all(bin.parent().unwrap()).unwrap();
    std::fs::write(&bin, "#!/bin/sh\ncase \"$*\" in --version) echo 'acpmux 0.1.0 (b1)';; esac\n")
        .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    // The /Applications glob of the real script, pointed at a temp folder.
    let apps = home.join("Applications");
    let app_bin = apps.join("cmux NIGHTLY.app/Contents/Resources/bin");
    std::fs::create_dir_all(&app_bin).unwrap();
    std::fs::copy(&bin, app_bin.join("acpmux")).unwrap();
    let script = probe_script().replace("/Applications/", &format!("{}/", apps.display()));
    let out = std::process::Command::new("sh")
        .args(["-c", &script])
        .env("HOME", &home)
        .env("PATH", "/usr/bin:/bin")
        .output()
        .unwrap();
    let p = parse_probe(&String::from_utf8_lossy(&out.stdout));
    let paths: Vec<&str> = p.bins.iter().map(|(path, _)| path.as_str()).collect();
    let app = app_bin.join("acpmux");
    assert_eq!(paths, [bin.to_str().unwrap(), app.to_str().unwrap()]);
    assert!(p.bins.iter().all(|(_, b)| b.as_deref() == Some("b1")));
    assert_eq!(p.running, None);
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn cmux_own_acpmux_is_never_replaced_or_started_beside() {
    let build = crate::hub::BUILD;
    let both: &[(&str, &str)] = &[(LOCAL_BIN, "old"), (APP_BIN, build)];
    for fix in [false, true] {
        // The app's daemon runs, this build: ok, though ~/.local/bin is old.
        let fake = host_with(both, Some((build, true)), APP_EXE, "");
        let results = machine_steps(
            &fake,
            &plan(&[]),
            &Local { harness_dir: None, home: None },
            fix,
            &mut |_| {},
        )
        .0;
        assert_eq!(
            states(&results)[1..3],
            [(Step::Install, StepState::Ok), (Step::Daemon, StepState::Ok)]
        );
        assert!(results[1].detail.contains("cmux's own acpmux"), "{results:?}");
        assert_read_only(&fake);

        // The app's daemon runs an older build: warn, name the matching CLI
        // or the install command, never "update".
        let app: &[(&str, &str)] = &[(APP_BIN, "old")];
        let fake = host_with(app, Some(("old", false)), APP_EXE, "");
        let results = machine_steps(
            &fake,
            &plan(&[]),
            &Local { harness_dir: None, home: None },
            fix,
            &mut |_| {},
        )
        .0;
        assert_eq!(
            states(&results)[1..3],
            [(Step::Install, StepState::Warn), (Step::Daemon, StepState::Warn)]
        );
        assert_eq!(
            results[1].detail,
            format!("leo@box.tail runs cmux's own acpmux (build old, this is {build})")
        );
        assert_eq!(
            results[1].fix.as_deref(),
            Some(
                "Enroll leo@box.tail from a cmux of build old, or use cmux > Check for Updates in the cmux app on leo@box.tail."
            )
        );
        assert_eq!(results[3].state, StepState::Skip, "no harness asked for");
        assert_read_only(&fake);

        // The app is installed, its daemon is not running: open cmux.
        let app_only = [(APP_BIN, build)];
        let fake = host_with(&app_only, None, "", "");
        let results = machine_steps(
            &fake,
            &plan(&[]),
            &Local { harness_dir: None, home: None },
            fix,
            &mut |_| {},
        )
        .0;
        assert_eq!(
            states(&results)[1..3],
            [(Step::Install, StepState::Ok), (Step::Daemon, StepState::Fail)]
        );
        assert_eq!(results[2].fix.as_deref(), Some("Open cmux on leo@box.tail, then check again."));
        assert_read_only(&fake);
    }
    // A daemon whose executable the host does not name, on a host with the
    // app: the app's, even when it answered through ~/.local/bin.
    let fake = host_with(both, Some(("old", false)), "", "");
    let results = machine_steps(
        &fake,
        &plan(&[]),
        &Local { harness_dir: None, home: None },
        true,
        &mut |_| {},
    )
    .0;
    assert_eq!(results[2].state, StepState::Warn);
    assert_read_only(&fake);
}

#[test]
fn doctor_without_fix_changes_nothing() {
    let build = crate::hub::BUILD;
    let local = local_with("nofix", "pi", "command = \"/Users/leo/bin/pi\"\n");
    // An old standalone build (warn); a stopped daemon; a stale profile;
    // nothing installed at all.
    let old: &[(&str, &str)] = &[(LOCAL_BIN, "old")];
    let current: &[(&str, &str)] = &[(LOCAL_BIN, build)];
    let scenarios: [(&[(&str, &str)], Option<(&str, bool)>, &str, StepState); 4] = [
        (old, Some(("old", false)), build, StepState::Warn),
        (current, None, build, StepState::Fail),
        (current, Some((build, false)), "stale", StepState::Fail),
        (&[], None, build, StepState::Fail),
    ];
    for (bins, daemon, profile, worst) in scenarios {
        let fake = host_with(bins, daemon, LOCAL_BIN, profile);
        let mut lines = Vec::new();
        let results =
            machine_steps(&fake, &plan(&["pi"]), &local, false, &mut |r| lines.push(step_line(r)))
                .0;
        assert_eq!(lines.len(), 4);
        assert!(results.iter().any(|r| r.state == worst), "{results:?}");
        assert_read_only(&fake);
    }
    let fake = host_with(old, Some(("old", false)), LOCAL_BIN, build);
    let results = machine_steps(&fake, &plan(&[]), &local, false, &mut |_| {}).0;
    assert_eq!(
        states(&results)[1..3],
        [(Step::Install, StepState::Warn), (Step::Daemon, StepState::Warn)]
    );
    assert_eq!(results[2].fix.as_deref(), Some("Run `acpmux host update box`."));
    assert_eq!(results[1].reason, Some("peer_version_skew"));
    assert_eq!(results[1].data.as_ref().unwrap()["try"], "acpmux host update box");
    assert_eq!(results[2].reason, Some("peer_version_skew"));
    assert_eq!(results[2].data.as_ref().unwrap()["try"], "acpmux host update box");
}

#[test]
fn enroll_copies_a_stale_profile_rewritten_and_owner_only() {
    let build = crate::hub::BUILD;
    let local = local_with("fix", "pi", "command = \"/Users/leo/bin/pi\"\n");
    let written: RefCell<Option<String>> = RefCell::default();
    let bins: &[(&str, &str)] = &[(LOCAL_BIN, build)];
    let fake = Fake::new(|script, stdin| {
        if let Some(bytes) = stdin {
            *written.borrow_mut() = Some(String::from_utf8(bytes.to_vec()).unwrap());
            return out("");
        }
        if script == "true" {
            out("")
        } else if script == probe_script().as_str() {
            out(probe_out_with(bins, Some((build, false)), LOCAL_BIN, Some(false)))
        } else if script.starts_with("printf 'bin=") {
            out(version(build))
        } else if script.starts_with("printf %s") {
            out("/home/leo")
        } else if script.contains("id -u") {
            // Group-writable until the copy replaces it.
            match written.borrow().as_deref() {
                Some(body) => {
                    out(format!("1000\n-rw------- 1 1000 1000 9 Oct 20 12:00 f\n\0{body}"))
                }
                None => out("1000\n-rw-rw-r-- 1 1000 1000 9 Oct 20 12:00 f\n\0old"),
            }
        } else {
            panic!("unexpected script: {script}")
        }
    });
    let results = machine_steps(&fake, &plan(&["pi"]), &local, true, &mut |_| {}).0;
    assert_eq!(
        states(&results),
        [
            (Step::Reach, StepState::Ok),
            (Step::Install, StepState::Ok),
            (Step::Daemon, StepState::Ok),
            (Step::Harness, StepState::Fixed)
        ]
    );
    assert_eq!(written.borrow().as_deref(), Some("command = \"/home/leo/bin/pi\"\n"));
    let calls = fake.calls.borrow();
    let (write, _) = calls.iter().find(|(_, stdin)| *stdin).unwrap();
    assert!(write.contains("chmod 700 \"$d\"") && write.contains("chmod 600"), "{write}");
    assert!(!write.contains("/home/leo/bin/pi"), "the profile goes over stdin");
}

#[test]
fn install_refuses_another_platform_and_reach_failure_skips_the_rest() {
    let fake = Fake::new(|script, _| {
        if script == "true" {
            out("")
        } else if script == probe_script().as_str() {
            out("\0")
        } else if script.starts_with("printf 'bin=") {
            out("bin=\n")
        } else if script == "uname -sm" {
            out("Plan9 mips")
        } else {
            panic!("unexpected script: {script}")
        }
    });
    let results = machine_steps(
        &fake,
        &plan(&[]),
        &Local { harness_dir: None, home: None },
        true,
        &mut |_| {},
    )
    .0;
    assert_eq!(results[1].state, StepState::Fail);
    assert_eq!(results[1].reason, Some(REASON_WRONG_PLATFORM), "the app installs the right build");
    assert_eq!(serde_json::to_value(&results[1]).unwrap()["reason"], "wrong-platform");
    assert!(results[1].fix.as_deref().unwrap().contains("cmux remote install"));
    assert!(fake.pushes.borrow().is_empty());
    assert_eq!(results[2].detail, "needs install");

    let fake = Fake::new(|_, _| RemoteOut {
        ok: false,
        stdout: String::new(),
        stderr: "leo@box.tail: Permission denied (publickey).".into(),
    });
    let results = machine_steps(
        &fake,
        &plan(&["pi"]),
        &Local { harness_dir: None, home: None },
        true,
        &mut |_| {},
    )
    .0;
    assert_eq!(results[0].state, StepState::Fail);
    assert!(results[0].detail.starts_with("the ssh key was rejected"));
    assert!(results[1..].iter().all(|r| r.state == StepState::Skip));
    assert_eq!(fake.calls.borrow().len(), 1);
}

/// Runs the scripts in a local `sh` with `HOME` at a temp folder, so the
/// harness scripts meet a real shell, `ls` and file modes.
#[cfg(unix)]
struct Sh(PathBuf);

#[cfg(unix)]
impl Remote for Sh {
    fn host(&self) -> &str {
        "sh"
    }
    fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut> {
        let mut child = std::process::Command::new("sh")
            .args(["-c", script])
            .env("HOME", &self.0)
            .env_remove("XDG_CONFIG_HOME")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()?;
        let mut pipe = child.stdin.take().unwrap();
        std::io::Write::write_all(&mut pipe, stdin.unwrap_or_default())?;
        drop(pipe);
        let out = child.wait_with_output()?;
        Ok(RemoteOut {
            ok: out.status.success(),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        })
    }
    fn push(&self, _local: &Path, _remote: &str) -> Result<()> {
        unreachable!()
    }
    fn spawn(&self, _script: &str) -> Result<std::process::Child> {
        unreachable!()
    }
}

#[test]
#[cfg(unix)]
fn the_harness_scripts_copy_owner_only_and_catch_a_writable_profile() {
    use std::os::unix::fs::PermissionsExt;
    let local = local_with("sh", "pi", "command = \"/Users/leo/bin/pi\"\n");
    let home = std::env::temp_dir().join(format!("acpmux-enroll-sh-home-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let sh = Sh(home.clone());
    let ids = vec!["pi".to_string()];
    assert_eq!(harness(&sh, "box", &ids, &local, false).state, StepState::Fail);
    let fixed = harness(&sh, "box", &ids, &local, true);
    assert_eq!(fixed.state, StepState::Fixed, "{fixed:?}");
    assert_eq!(fixed.detail, "pi copied (missing)");
    let dir = home.join(".config/cmux/harnesses");
    let file = dir.join("pi.toml");
    let remote_home = home.to_string_lossy();
    assert_eq!(
        std::fs::read_to_string(&file).unwrap(),
        format!("command = \"{remote_home}/bin/pi\"\n")
    );
    assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
    assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(harness(&sh, "box", &ids, &local, false).state, StepState::Ok);
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o664)).unwrap();
    let writable = harness(&sh, "box", &ids, &local, false);
    assert_eq!(writable.state, StepState::Fail);
    assert!(writable.detail.contains("group- or other-writable"), "{writable:?}");
    assert_eq!(harness(&sh, "box", &ids, &local, true).state, StepState::Fixed);
    assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
#[cfg(unix)]
fn the_probe_finds_a_cmux_tui_and_asks_it_through_acp() {
    use std::os::unix::fs::PermissionsExt;
    let home = std::env::temp_dir().join(format!("acpmux-enroll-tui-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    // Answers only as `cmux-tui acp …`, as the real one does.
    let script = "#!/bin/sh\ncase \"$*\" in 'acp --version') echo 'acpmux 0.1.0 (t1)';; esac\n";
    let mut paths = Vec::new();
    for dir in [".local/bin", ".cmux/bin"] {
        let bin = home.join(dir).join("cmux-tui");
        std::fs::create_dir_all(bin.parent().unwrap()).unwrap();
        std::fs::write(&bin, script).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        paths.push(bin.to_string_lossy().into_owned());
    }
    let script =
        probe_script().replace("/Applications/", &format!("{}/Applications/", home.display()));
    let out = std::process::Command::new("sh")
        .args(["-c", &script])
        .env("HOME", &home)
        .env("PATH", "/usr/bin:/bin")
        .output()
        .unwrap();
    let p = parse_probe(&String::from_utf8_lossy(&out.stdout));
    assert_eq!(
        p.bins,
        paths.iter().map(|b| (b.clone(), Some("t1".to_owned()))).collect::<Vec<_>>()
    );
    assert_eq!(p.current_cmux_tui("t1"), Some(paths[0].as_str()));
    assert_eq!(p.current_cmux_tui("other"), None);
    let _ = std::fs::remove_dir_all(&home);
}

/// A host the app installed its cmux-tui on (this build) without the
/// `~/.local/bin/acpmux` link; linking makes it current.
fn tui_only_host(linked: &RefCell<bool>) -> Fake<impl Fn(&str, Option<&[u8]>) -> RemoteOut + '_> {
    let build = crate::hub::BUILD;
    Fake::new(move |script, _| {
        let is_linked = *linked.borrow();
        if script == "true" {
            out("")
        } else if script == probe_script().as_str() {
            let mut bins = vec![(TUI_BIN, build)];
            if is_linked {
                bins.insert(0, (LOCAL_BIN, build));
            }
            out(probe_out(&bins, None))
        } else if script.starts_with("printf 'bin=") && script.contains("cmux-tui acp --version") {
            let daemon = if is_linked { format!("acpmux 0.1.0 ({build})") } else { String::new() };
            out(format!("bin=acpmux 0.1.0 ({build})\ndaemon={daemon}\n"))
        } else if script.starts_with("printf 'bin=") {
            out(if is_linked { version(build) } else { "bin=\n".into() })
        } else if script.contains("ln -s") {
            assert!(script.contains(&format!("ln -s {TUI_BIN} {DAEMON_BIN}")), "{script}");
            *linked.borrow_mut() = true;
            out("")
        } else {
            panic!("unexpected script: {script}")
        }
    })
}

#[test]
fn a_host_whose_only_gap_is_the_link_gets_linked_not_pushed() {
    let build = crate::hub::BUILD;
    // Without --fix: the link is named as missing, nothing changes.
    let linked = RefCell::new(false);
    let fake = tui_only_host(&linked);
    let r = install(&fake, "box", DAEMON_BIN, false);
    assert_eq!(r.state, StepState::Fail, "{r:?}");
    assert_eq!(r.detail, format!("{DAEMON_BIN} is missing"));
    assert_eq!(r.reason, None, "nothing for the app to install");
    assert!(serde_json::to_value(&r).unwrap().get("reason").is_none());
    assert_read_only(&fake);

    // With --fix: one link, no push and no platform check (that would fail
    // for a host of another OS than this program's).
    let fake = tui_only_host(&linked);
    let r = install(&fake, "box", DAEMON_BIN, true);
    assert_eq!(r.state, StepState::Fixed, "{r:?}");
    assert_eq!(r.detail, format!("{DAEMON_BIN} is missing; linked {DAEMON_BIN} to {TUI_BIN}"));
    assert!(fake.pushes.borrow().is_empty());
    assert!(!fake.calls.borrow().iter().any(|(s, _)| s.contains("uname")));

    assert!(
        fake.fenced.borrow().iter().any(|s| s.contains(&format!("ln -s {TUI_BIN} {DAEMON_BIN}"))),
        "the link holds the host's update lock"
    );

    // Linked: the next check passes as it is.
    let fake = tui_only_host(&linked);
    let r = install(&fake, "box", DAEMON_BIN, true);
    assert_eq!(r.state, StepState::Ok, "{r:?}");
    assert_eq!(r.detail, format!("{DAEMON_BIN} is build {build}"));
    assert_read_only(&fake);
}

#[test]
fn enroll_never_relinks_the_daemon_binary_while_another_update_runs() {
    // Re-review of #24232: `enroll --fix` linked ~/.local/bin/acpmux to the
    // app's cmux-tui while the host's timer was mid-update; the timer then
    // checked the wrong binary, rolled back and marked its healthy build as
    // rolled back for good. The link now takes the host's update lock.
    let linked = RefCell::new(false);
    let fake = tui_only_host(&linked);
    fake.locked.set(true);
    let r = install(&fake, "box", DAEMON_BIN, true);
    assert_eq!(r.state, StepState::Fail, "{r:?}");
    assert!(r.detail.contains("another update of leo@box.tail is running"), "{r:?}");
    assert!(!*linked.borrow(), "nothing was linked");
    assert!(!fake.calls.borrow().iter().any(|(s, _)| s.contains("ln -s")));
    assert!(fake.pushes.borrow().is_empty());
}

#[test]
fn no_standalone_daemon_starts_beside_an_installed_app() {
    let build = crate::hub::BUILD;
    // A standalone acpmux first, the app second, no daemon running: the
    // app's host, so nothing is started.
    let bins: &[(&str, &str)] = &[(LOCAL_BIN, build), (APP_BIN, build)];
    let p = parse_probe(&probe_out(bins, None));
    let used = p.in_use().unwrap();
    assert!(used.app && used.pid.is_none());
    assert_eq!(used.path, APP_BIN);
    for fix in [false, true] {
        let fake = host_with(bins, None, "", "");
        let results = machine_steps(
            &fake,
            &plan(&[]),
            &Local { harness_dir: None, home: None },
            fix,
            &mut |_| {},
        )
        .0;
        assert_eq!(
            states(&results)[1..3],
            [(Step::Install, StepState::Ok), (Step::Daemon, StepState::Fail)]
        );
        assert_eq!(results[2].fix.as_deref(), Some("Open cmux on leo@box.tail, then check again."));
        assert_read_only(&fake);
    }
    // Without an app, the first binary is used and is not the app's.
    let p = parse_probe(&probe_out(&[(LOCAL_BIN, build), (TUI_BIN, build)], None));
    assert!(!p.in_use().unwrap().app);
}

#[test]
fn a_daemon_running_as_cmux_tui_acp_is_cmux_own() {
    // The daemon decides from its own command line (`hub/views.rs`).
    let acp = |line: &str| crate::hub::views::runs_as_cmux_tui_acp(line.split_whitespace());
    assert!(acp("/home/leo/.local/bin/cmux-tui acp daemon run"));
    assert!(acp("cmux-tui acp daemon-run --home /x"));
    assert!(!acp("/home/leo/.local/bin/acpmux daemon run"));
    assert!(!acp("/home/leo/.local/bin/cmux-tui remote serve"));
    assert!(!acp(""));
    let build = crate::hub::BUILD;
    let bins: &[(&str, &str)] = &[(TUI_BIN, build)];
    let mut p = parse_probe(&probe_out(bins, Some((build, false))));
    assert!(!p.in_use().unwrap().app);
    p.run_by_cmux_tui = true;
    let used = p.in_use().unwrap();
    assert!(used.app && used.pid == Some(7));
    // Never restarted, even when its listener is missing.
    p.config = "{}".into();
    match judge_daemon("leo@box.tail", "box", &p, Some(47811)).0 {
        Verdict::Done(r) => assert_eq!(r.state, StepState::Fail, "{r:?}"),
        other => panic!("{other:?}"),
    }
}

#[test]
fn peer_back_is_skipped_unless_asked() {
    let r = peer_back_off();
    assert_eq!((r.step, r.state), (Step::PeerBack, StepState::Skip));
    assert!(r.detail.contains("--reverse"), "{}", r.detail);
}

#[test]
fn a_daemon_started_through_the_acpmux_link_stays_ours() {
    // A cmux session daemon's: another file than the link resolves to, or no link.
    assert!(cmux_session_daemon(true, Some(TUI_BIN), ""));
    assert!(cmux_session_daemon(true, Some(TUI_BIN), "/opt/acpmux/acpmux"));
    assert!(cmux_session_daemon(true, None, LOCAL_BIN));
    // Enroll's own, started as ~/.local/bin/acpmux -> cmux-tui: the exe is
    // the link's target (also after the file was replaced).
    assert!(!cmux_session_daemon(true, Some(TUI_BIN), TUI_BIN));
    assert!(!cmux_session_daemon(true, Some(&format!("{TUI_BIN} (deleted)")), TUI_BIN));
    assert!(!cmux_session_daemon(false, Some(LOCAL_BIN), ""));

    // Through probe(): the daemon names its exe and says it runs as
    // `cmux-tui acp` in its status; only the link is resolved on the host. The link's daemon is
    // repairable, not cmux's.
    let build = crate::hub::BUILD;
    let bins: &[(&str, &str)] = &[(LOCAL_BIN, build), (TUI_BIN, build)];
    for (link_target, ours) in [(TUI_BIN, true), ("", false)] {
        let fake = Fake::new(|script, _| {
            if script == probe_script().as_str() {
                out(probe_out_with(bins, Some((build, false)), TUI_BIN, Some(true)))
            } else if script == format!("readlink -f {DAEMON_BIN} 2>/dev/null") {
                out(format!("{link_target}\n"))
            } else {
                panic!("unexpected script: {script}")
            }
        });
        let p = probe(&fake).unwrap();
        assert_eq!(p.exe.as_deref(), Some(TUI_BIN));
        assert_eq!(p.in_use().unwrap().app, !ours, "link target {link_target:?}");
        assert_eq!(fake.calls.borrow().len(), 2);
    }
}

#[test]
fn the_probe_never_scans_processes() {
    let build = crate::hub::BUILD;
    let bins: &[(&str, &str)] = &[(LOCAL_BIN, build)];
    // A standalone daemon (`acpmux daemon run`) and one too old to say who
    // it is: the status alone answers, one script in all.
    for (exe, acp) in [(LOCAL_BIN, Some(false)), ("", None)] {
        let fake = Fake::new(|script, _| {
            assert_eq!(script, probe_script().as_str(), "a second script");
            out(probe_out_with(bins, Some((build, false)), exe, acp))
        });
        let p = probe(&fake).unwrap();
        assert_eq!(p.exe.as_deref(), (!exe.is_empty()).then_some(exe));
        assert!(!p.run_by_cmux_tui);
        assert_eq!(fake.calls.borrow().len(), 1);
    }
    for scan in ["/proc/", "ps -", "pgrep", "lsof"] {
        assert!(!probe_script().contains(scan), "{scan}");
    }
}

#[test]
fn a_daemon_too_old_to_say_who_it_is_counts_as_cmux_own_beside_a_cmux() {
    let build = crate::hub::BUILD;
    let local = Local { harness_dir: None, home: None };
    // Linux: an older `cmux-tui acp` session daemon answers through the
    // standalone acpmux; the cmux-tui is there. Never installed or
    // restarted beside, even with --fix: it warns, naming `cmux remote install`.
    let tui: &[(&str, &str)] = &[(LOCAL_BIN, "old"), (TUI_BIN, build)];
    let fake = host_reporting(tui, Some(("old", false)), "", None, "");
    let used = probe(&fake).unwrap().in_use().unwrap();
    assert!(used.app && !used.bundle, "{used:?}");
    let fake = host_reporting(tui, Some(("old", false)), "", None, "");
    let results = machine_steps(&fake, &plan(&[]), &local, true, &mut |_| {}).0;
    assert_eq!(
        states(&results)[1..3],
        [(Step::Install, StepState::Warn), (Step::Daemon, StepState::Warn)]
    );
    assert_eq!(
        results[1].fix.as_deref(),
        Some(
            "Enroll leo@box.tail from a cmux of build old, or run `cmux remote install` for leo@box.tail."
        )
    );
    assert_read_only(&fake);

    // macOS: a cmux app and an older daemon that answered through
    // ~/.local/bin: the app's, so it warns and names the app's updater.
    let app: &[(&str, &str)] = &[(LOCAL_BIN, "old"), (APP_BIN, build)];
    let fake = host_reporting(app, Some(("old", false)), "", None, "");
    let results = machine_steps(&fake, &plan(&[]), &local, true, &mut |_| {}).0;
    assert_eq!(
        states(&results)[1..3],
        [(Step::Install, StepState::Warn), (Step::Daemon, StepState::Warn)]
    );
    assert!(results[1].fix.as_deref().unwrap().contains("Check for Updates"), "{results:?}");
    assert_read_only(&fake);

    // The same daemon alone (no cmux-tui, no app) stays repairable.
    let alone: &[(&str, &str)] = &[(LOCAL_BIN, "old")];
    let p = parse_probe(&probe_out_with(alone, Some(("old", false)), "", None));
    assert!(!p.in_use().unwrap().app);
}

#[test]
fn a_keyed_cmux_tui_daemon_on_an_ssh_host_names_remote_install() {
    // The app starts an SSH host's `cmux-tui acp daemon start --person-key-fd 0`
    // (SSHService+PersonKey.swift): cmux's own, but no app bundle runs it.
    let tui: &[(&str, &str)] = &[(TUI_BIN, "old")];
    let fake = host_reporting(tui, Some(("old", true)), TUI_BIN, Some(true), "");
    let results = machine_steps(
        &fake,
        &plan(&[]),
        &Local { harness_dir: None, home: None },
        true,
        &mut |_| {},
    )
    .0;
    assert_eq!(
        states(&results)[1..3],
        [(Step::Install, StepState::Warn), (Step::Daemon, StepState::Warn)]
    );
    assert_eq!(
        results[1].fix.as_deref(),
        Some(
            "Enroll leo@box.tail from a cmux of build old, or run `cmux remote install` for leo@box.tail."
        )
    );
    assert_read_only(&fake);
}

/// Two daemons on one Linux host, as one user sees it (ergo-walk, 2026-10-25):
/// that user's own daemon (`~/.acpmux`, this build) listening on `ours`
/// (None: no listener), and the host's shared daemon on 47811, which the
/// user cannot see but whose port nobody else can bind. A restart binds the
/// port the written config names, except 47811: the restarted daemon moves
/// to the free 46673 and saves it (`daemon.rs`, a taken configured port).
fn two_daemon_host(ours: Option<u16>) -> Fake<impl Fn(&str, Option<&[u8]>) -> RemoteOut> {
    two_daemon_host_with(ours, true)
}

/// [`two_daemon_host`]; without `token` its config holds no listener at all
/// (a daemon run with `--listen` and `--token`).
fn two_daemon_host_with(
    ours: Option<u16>,
    token: bool,
) -> Fake<impl Fn(&str, Option<&[u8]>) -> RemoteOut> {
    let build = crate::hub::BUILD;
    let listen = RefCell::new(ours);
    let written = RefCell::new(None::<u16>);
    Fake::new(move |script, stdin| {
        let config = |port: Option<u16>| match port.filter(|_| token) {
            Some(p) => format!(r#"{{"websocket":{{"listen":"127.0.0.1:{p}","token":"t"}}}}"#),
            None => "{}".to_owned(),
        };
        if let Some(text) = stdin {
            let cfg: Value = serde_json::from_slice(text).expect("a config");
            let addr = cfg.pointer("/websocket/listen").and_then(Value::as_str).unwrap();
            *written.borrow_mut() = addr.rsplit_once(':').and_then(|(_, p)| p.parse().ok());
            out("")
        } else if script == "true" {
            out("")
        } else if script == probe_script().as_str() {
            let port = *listen.borrow();
            let status = json!({
                "pid": 7, "build": build, "personKey": false, "exe": LOCAL_BIN,
                "runsAsCmuxTuiAcp": false,
                "listen": port.map(|p| format!("127.0.0.1:{p}")),
            });
            out(format!(
                "bin\t{LOCAL_BIN}\tacpmux 0.1.0 ({build})\nstatus\t{LOCAL_BIN}\t{status}\n\0{}",
                config(port)
            ))
        } else if script.starts_with("printf 'bin=") {
            out(version(build))
        } else if script.starts_with("cat ~/.acpmux/config.json") {
            out(config(*listen.borrow()))
        } else if script == "uname -s" {
            out("Linux")
        } else if script.contains("acpmux.service") {
            let want = written.borrow().expect("a restart after the config write");
            *listen.borrow_mut() = Some(if want == 47811 { 46673 } else { want });
            out("started")
        } else {
            panic!("unexpected script: {script}")
        }
    })
}

fn enroll_plan() -> Plan {
    Plan::enroll("leo@box.tail".into(), Some("box".into()), vec![], DAEMON_BIN.into(), false)
}

#[test]
fn enroll_keeps_the_listener_of_a_daemon_on_another_port() {
    // The user's daemon runs healthy on 47921 beside the host's on 47811:
    // enroll peers with it there, and never rewrites or restarts it.
    let fake = two_daemon_host(Some(47921));
    let local = Local { harness_dir: None, home: None };
    let (results, port) = machine_steps(&fake, &enroll_plan(), &local, true, &mut |_| {});
    assert_eq!(port, 47921);
    assert_eq!(
        states(&results)[..3],
        [
            (Step::Reach, StepState::Ok),
            (Step::Install, StepState::Ok),
            (Step::Daemon, StepState::Ok)
        ],
        "{results:?}"
    );
    assert_read_only(&fake);
}

#[test]
fn enroll_never_takes_the_port_another_daemon_holds() {
    // No listener yet, and the default 47811 is the host daemon's: the
    // restarted daemon moves to a free port, and enroll peers there.
    let fake = two_daemon_host(None);
    let local = Local { harness_dir: None, home: None };
    let (results, port) = machine_steps(&fake, &enroll_plan(), &local, true, &mut |_| {});
    assert_eq!(results[2].state, StepState::Fixed, "{results:?}");
    assert!(results[2].detail.contains("on port 46673"), "{results:?}");
    assert_eq!(port, 46673);
}

#[test]
fn doctor_refuses_to_move_a_healthy_daemon_to_the_peers_port() {
    // The peer names 47811 but the daemon runs healthy on 47921: no config
    // change and no restart, even with --fix; the fix points the peer at it.
    let fake = two_daemon_host(Some(47921));
    let local = Local { harness_dir: None, home: None };
    let results = machine_steps(&fake, &plan(&[]), &local, true, &mut |_| {}).0;
    assert_eq!(results[2].state, StepState::Fail, "{results:?}");
    assert!(
        results[2]
            .fix
            .as_deref()
            .unwrap()
            .contains("`acpmux host add box ssh://leo@box.tail:47921`"),
        "{results:?}"
    );
    assert_read_only(&fake);
}

#[test]
fn doctor_refuses_to_move_a_daemon_run_with_its_own_listener_and_token() {
    // `acpmux daemon run --listen 127.0.0.1:47921 --token T`: bound there, no
    // listener saved. The peer names 47811: refused before any write.
    let fake = two_daemon_host_with(Some(47921), false);
    let local = Local { harness_dir: None, home: None };
    let results = machine_steps(&fake, &plan(&[]), &local, true, &mut |_| {}).0;
    assert_eq!(results[2].state, StepState::Fail, "{results:?}");
    assert!(results[2].fix.as_deref().unwrap().contains("ssh://leo@box.tail:47921"), "{results:?}");
    assert_read_only(&fake);
}
