use super::*;

#[test]
fn first_contact_only_accepts_new_keys_when_requested() {
    let normal = ssh_argv("user@box", "true").unwrap();
    assert_eq!(first_contact_argv("user@box", false).unwrap(), normal);
    let opted_in = first_contact_argv("user@box", true).unwrap();
    assert_eq!(&opted_in[..2], ["-o", "StrictHostKeyChecking=accept-new"]);
    assert_eq!(&opted_in[2..], normal);
    assert!(first_contact_argv("-oProxyCommand=bad", true).is_err());
    // A later command or copy keeps the user's policy, even after an opted-in reach.
    assert_eq!(ssh_argv("user@box", "true").unwrap(), normal);
    assert!(
        !scp_push_argv("user@box", "local", "remote")
            .unwrap()
            .iter()
            .any(|arg| arg.contains("StrictHostKeyChecking"))
    );
}

/// What the remote login shell does with ssh's command string: runs it with `-c`.
fn as_login_shell(shell: &str, argv: &[String]) -> Option<String> {
    let out = std::process::Command::new(shell).arg("-c").arg(argv.last()?).output().ok()?;
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

#[test]
fn a_failed_push_carries_scps_words_on_one_line() {
    // The app tells an offline peer from a broken one by them (`AcpmuxPeerUpdateReply`).
    let e = scp_failed("h", "client_loop: send disconnect: Broken pipe\r\nlost connection\n");
    assert_eq!(
        e.to_string(),
        "scp to h failed: client_loop: send disconnect: Broken pipe lost connection"
    );
    assert_eq!(scp_failed("h", " \n").to_string(), "scp to h failed");
}

#[test]
fn a_remote_script_runs_the_same_under_zsh_bash_and_sh_login_shells() {
    // macOS logs in with zsh, where an unmatched glob aborts the whole command
    // ("no matches found"): enroll's probe saw no daemon and no config on a Mac
    // without a cmux app. Every script runs under /bin/sh whatever the login shell.
    let script = "for f in /nonexistent-cmux*.app/x; do [ -e \"$f\" ] && echo hit; done; printf 'after %s\\n' \"it's\"";
    let argv = ssh_argv("leo@huge-blue", script).unwrap();
    assert_eq!(
        &argv[..10],
        [
            "-o",
            "BatchMode=yes",
            "-o",
            "ServerAliveInterval=10",
            "-o",
            "ServerAliveCountMax=3",
            "-o",
            "ConnectTimeout=15",
            "--",
            "leo@huge-blue"
        ]
    );
    for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
        if !std::path::Path::new(shell).exists() {
            continue;
        }
        assert_eq!(as_login_shell(shell, &argv).as_deref(), Some("after it's\n"), "{shell}");
    }
    assert_eq!(script_of(&argv[10]).as_deref(), Some(script));
}

#[test]
fn a_command_that_does_not_answer_in_time_is_stopped_and_named() {
    let started = std::time::Instant::now();
    let mut slow = Command::new("/bin/sh");
    slow.args(["-c", "sleep 30"]);
    let why = bounded_ok(&mut slow, std::time::Duration::from_secs(1)).unwrap_err();
    assert_eq!(why, "no answer within 1 s");
    assert!(started.elapsed() < std::time::Duration::from_secs(10));
}

/// Review of #27696: the timeout ends what the command started too (a
/// ProxyCommand), not only the command, and nothing holds the call after.
#[test]
#[cfg(unix)]
fn a_timeout_leaves_nothing_the_command_started_running() {
    use std::os::fd::AsRawFd;
    use std::os::unix::process::CommandExt;
    // The command and its child hold the write end of a pipe as fd 3; the test holds the
    // read end. It reads end of file only once every holder has exited. A process that has
    // exited and not yet been reaped by its new parent (a zombie, which `kill(pid, 0)` still
    // finds) holds no file, so this checks that they ended, not when they were reaped: on a
    // loaded host init reaps the orphaned `sleep` later (full suites, 2026-11-01).
    // `std::io::pipe` makes both ends close-on-exec at once, so a process another test
    // starts at the same moment never holds the write end (`tests/person_auto_start.rs`).
    let (reader, writer) = std::io::pipe().unwrap();
    let write_end = writer.as_raw_fd();
    let mut cmd = Command::new("/bin/sh");
    cmd.args(["-c", "sleep 60 >&2 & wait"]);
    // SAFETY: only dup2 and fcntl between fork and exec (async-signal-safe).
    unsafe {
        cmd.pre_exec(move || {
            if write_end == 3 {
                // dup2 onto itself keeps close-on-exec: clear it.
                if libc::fcntl(3, libc::F_SETFD, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
            } else if libc::dup2(write_end, 3) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let started = std::time::Instant::now();
    let why = bounded_ok(&mut cmd, std::time::Duration::from_secs(1)).unwrap_err();
    assert_eq!(why, "no answer within 1 s");
    assert!(started.elapsed() < std::time::Duration::from_secs(10));
    drop(writer);
    // The killed processes close their files as they exit; wait for that (bounded), then
    // read: end of file, or a holder still runs.
    let mut ready = libc::pollfd { fd: reader.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    // SAFETY: one valid pollfd for the duration of the call.
    let polled = unsafe { libc::poll(&raw mut ready, 1, 5_000) };
    assert_eq!(polled, 1, "something the command started still runs after 5 s");
    let mut byte = [0u8; 1];
    let n = std::io::Read::read(&mut &reader, &mut byte).unwrap();
    assert_eq!(n, 0, "something the command started wrote to the pipe");
}

/// A command that exits while something it started still holds its
/// stderr returns at once, and that something is ended.
#[test]
#[cfg(unix)]
fn an_exit_ends_what_still_holds_the_output() {
    let mut cmd = Command::new("/bin/sh");
    cmd.args(["-c", "sleep 60 >&2 & echo 'ssh: gone' >&2; exit 255"]);
    let started = std::time::Instant::now();
    let why = bounded_ok(&mut cmd, std::time::Duration::from_secs(30)).unwrap_err();
    assert_eq!(why, "ssh: gone");
    assert!(started.elapsed() < std::time::Duration::from_secs(10));
}

#[test]
fn a_command_that_fails_is_named_by_its_last_stderr_line() {
    let mut fails = Command::new("/bin/sh");
    fails.args([
        "-c",
        "echo first >&2; echo 'ssh: connect to host x port 22: Operation timed out' >&2; exit 255",
    ]);
    let why = bounded_ok(&mut fails, std::time::Duration::from_secs(10)).unwrap_err();
    assert_eq!(why, "ssh: connect to host x port 22: Operation timed out");
    let mut quiet = Command::new("/bin/sh");
    quiet.args(["-c", "exit 3"]);
    let why = bounded_ok(&mut quiet, std::time::Duration::from_secs(10)).unwrap_err();
    assert!(why.starts_with("it exited with "), "{why}");
    let mut ok = Command::new("/bin/sh");
    ok.args(["-c", "true"]);
    assert_eq!(bounded_ok(&mut ok, std::time::Duration::from_secs(10)), Ok(()));
}

/// Records each script and its stdin; answers ok with `stdout`.
struct Recorder(std::cell::RefCell<Vec<(String, Option<Vec<u8>>)>>, &'static str);

impl Remote for Recorder {
    fn host(&self) -> &str {
        "box"
    }
    fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut> {
        self.0.borrow_mut().push((script.to_owned(), stdin.map(<[u8]>::to_vec)));
        Ok(RemoteOut { ok: true, stdout: self.1.into(), stderr: String::new() })
    }
    fn push(&self, _: &Path, _: &str) -> Result<()> {
        unreachable!()
    }
    fn spawn(&self, _: &str) -> Result<Child> {
        unreachable!()
    }
}

#[test]
fn the_config_and_its_token_go_over_stdin_not_the_command_line() {
    let r = Recorder(Default::default(), "");
    let cfg = daemon_config("{}", 47811, "secret-token-123");
    write_config(&r, &serde_json::to_string_pretty(&cfg).unwrap()).unwrap();
    let calls = r.0.borrow();
    let (script, stdin) = &calls[0];
    assert!(!script.contains("secret-token-123"), "{script}");
    assert_eq!(script, &config_write_script());
    for keep in ["chmod 700", "umask 077", "chmod 600", "cat > "] {
        assert!(script.contains(keep), "{keep}: {script}");
    }
    let stdin = String::from_utf8(stdin.clone().expect("stdin")).unwrap();
    assert!(stdin.contains("secret-token-123"));
}

#[test]
#[cfg(unix)]
fn the_config_script_writes_an_owner_only_file() {
    use std::os::unix::fs::PermissionsExt;
    let home = std::env::temp_dir().join(format!("acpmux-cfg-write-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let mut child = std::process::Command::new("sh")
        .args(["-c", &config_write_script()])
        .env("HOME", &home)
        .stdin(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    std::io::Write::write_all(&mut child.stdin.take().unwrap(), b"{\"x\":1}\n").unwrap();
    assert!(child.wait().unwrap().success());
    let dir = home.join(REMOTE_HOME.trim_start_matches("~/"));
    let file = dir.join("config.json");
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "{\"x\":1}\n");
    assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
    assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn peer_urls_name_a_port_only_off_the_default() {
    assert_eq!(ssh_peer_url("hb", 47811), "ssh://hb");
    assert_eq!(ssh_peer_url("leo@hb", 47900), "ssh://leo@hb:47900");
}

#[test]
fn the_daemon_config_keeps_the_listener_settings_and_marks_a_new_token() {
    let existing = r#"{"websocket":{"listen":"0.0.0.0:1","token":"old","allowedOrigins":["https://a"],"allowedHosts":["h"],"tokenRotated":7},"store":{"mode":"cloud"},"x":1}"#;
    let cfg = daemon_config(existing, 47811, "fresh");
    let ws = &cfg["websocket"];
    assert_eq!(ws["listen"], "127.0.0.1:47811");
    assert_eq!(ws["token"], "old", "an existing token is kept");
    assert_eq!(ws["tokenRotated"], 7, "and its rotation count");
    assert_eq!(ws["allowedOrigins"], json!(["https://a"]));
    assert_eq!(ws["allowedHosts"], json!(["h"]));
    assert_eq!(cfg["store"], json!({"mode": "cloud"}));
    assert_eq!(cfg["x"], 1);
    assert_eq!(cfg["permissionPolicy"], "ask");

    // No token yet: the fresh one, marked rotated once; other keys stay.
    let cfg = daemon_config(r#"{"websocket":{"allowedHosts":["h"]}}"#, 47900, "fresh");
    assert_eq!(cfg["websocket"]["token"], "fresh");
    assert_eq!(cfg["websocket"]["tokenRotated"], 1);
    assert_eq!(cfg["websocket"]["allowedHosts"], json!(["h"]));
    assert_eq!(cfg["websocket"]["listen"], "127.0.0.1:47900");
    assert_eq!(cfg["store"], json!({"mode": "local"}));
    for broken in ["", "not json", "[]"] {
        let cfg = daemon_config(broken, 47811, "fresh");
        assert_eq!(cfg["websocket"]["token"], "fresh", "{broken:?}");
        assert_eq!(cfg["websocket"]["tokenRotated"], 1);
    }
}

/// The remote's shutdown step against a fake `~/.local/bin/acpmux` that
/// logs its arguments and exits as `body` says; the calls it got.
#[cfg(unix)]
fn remote_shutdown_calls(tag: &str, body: &str) -> Vec<String> {
    let home = std::env::temp_dir().join(format!("acpmux-rs-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join(".local/bin")).unwrap();
    let fake = home.join(".local/bin/acpmux");
    crate::test_exec::write_executable(
        &fake,
        format!("#!/bin/sh\necho \"$*\" >> \"$HOME/calls\"\n{body}\n"),
    );
    std::process::Command::new("sh")
        .args(["-c", SHUTDOWN_KEEPING_AGENTS])
        .env("HOME", &home)
        .status()
        .unwrap();
    let calls = std::fs::read_to_string(home.join("calls")).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&home);
    calls.lines().map(str::to_owned).collect()
}

/// A Linux host as the fake `systemctl` and `loginctl` answer.
#[derive(Clone, Copy)]
struct LinuxHost {
    /// A user systemd manager answers.
    manager: bool,
    /// `loginctl show-user -p Linger`; `enable-linger` succeeds when `linger_allowed`.
    linger: bool,
    linger_allowed: bool,
    /// `acpmux.service` runs.
    active: bool,
    /// `enable --now` succeeds.
    enables: bool,
    /// `restart` succeeds.
    restarts: bool,
    /// `acpmux.service` is installed before the run (a host set up earlier).
    installed: bool,
    /// The installed unit's text, when not this build's [`SYSTEMD_UNIT`].
    installed_text: Option<&'static str>,
    /// `daemon-reload` succeeds.
    reloads: bool,
    /// `mktemp` works (no: a full `/tmp`).
    mktemp: bool,
    /// systemd has not read `acpmux.service` since it changed.
    need_reload: bool,
    /// A daemon of `~/.acpmux` runs, in this user unit's cgroup, or at this
    /// cgroup path when it starts with `/` (`None`: none runs).
    daemon_unit: Option<&'static str>,
    /// That daemon is still up after `daemon shutdown`.
    survives_shutdown: bool,
}

const LINGERING: LinuxHost = LinuxHost {
    manager: true,
    linger: true,
    linger_allowed: true,
    active: false,
    enables: true,
    restarts: true,
    installed: false,
    installed_text: None,
    reloads: true,
    mktemp: true,
    need_reload: false,
    daemon_unit: None,
    survives_shutdown: false,
};

struct LinuxRun {
    calls: Vec<String>,
    unit: String,
    /// The files in `~/.config/systemd/user` after the run.
    units: Vec<String>,
    out: String,
    err: String,
    code: Option<i32>,
}

/// `linux_restart(install, true)` in a fake home on `host`.
#[cfg(unix)]
fn linux_restart_run(tag: &str, install: bool, host: LinuxHost) -> LinuxRun {
    let home = std::env::temp_dir().join(format!("acpmux-lx-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let bin = home.join(".local/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let fake = |name: &str, body: &str| {
        let file = bin.join(name);
        crate::test_exec::write_executable(
            &file,
            format!("#!/bin/sh\necho \"{name} $*\" >> \"$HOME/calls\"\n{body}\n"),
        );
    };
    let code = |ok: bool| if ok { "exit 0" } else { "exit 1" };
    // The daemon answers `daemon status` until a shutdown it does not survive.
    let daemon = format!(
        "case \"$*\" in \"--json daemon status\") if {} && [ ! -f \"$HOME/stopped\" ]; then printf '{{\\n  \"version\": \"0.1.0\",\\n  \"pid\": 4242,\\n  \"ready\": true\\n}}\\n'; else printf '{{\\n  \"running\": false\\n}}\\n'; fi;; \"daemon shutdown\"*) {};; esac; exit 0",
        if host.daemon_unit.is_some() { "true" } else { "false" },
        if host.survives_shutdown { ":" } else { "touch \"$HOME/stopped\"" },
    );
    fake("acpmux", &daemon);
    fake(
        "systemctl",
        &format!(
            "case \"$2\" in show-environment) {};; cat) test -f \"$HOME/.config/systemd/user/$3\";; is-active) {};; enable) {};; restart) {};; daemon-reload) {};; show) case \"$5\" in LoadState) echo not-found;; *) echo {};; esac;; *) exit 0;; esac",
            code(host.manager),
            if host.active { "exit 0" } else { "exit 3" },
            code(host.enables),
            code(host.restarts),
            code(host.reloads),
            if host.need_reload { "yes" } else { "no" },
        ),
    );
    if !host.mktemp {
        fake("mktemp", "exit 1");
    }
    fake(
        "loginctl",
        &format!(
            "case \"$1\" in show-user) echo {};; enable-linger) {};; esac",
            if host.linger { "yes" } else { "no" },
            code(host.linger_allowed),
        ),
    );
    if host.installed {
        let dir = home.join(".config/systemd/user");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("acpmux.service"), host.installed_text.unwrap_or(SYSTEMD_UNIT))
            .unwrap();
    }
    if let Some(unit) = host.daemon_unit {
        std::fs::create_dir_all(home.join("proc/4242")).unwrap();
        std::fs::write(
            home.join("proc/4242/cgroup"),
            match unit.strip_prefix('/') {
                Some(path) => format!("0::/{path}\n"),
                None => {
                    format!("0::/user.slice/user-1001.slice/user@1001.service/app.slice/{unit}\n")
                }
            },
        )
        .unwrap();
    }
    let script = linux_restart(install, true)
        .replace("/proc/", &format!("{}/", home.join("proc").display()));
    let out = std::process::Command::new("sh")
        .args(["-c", &script])
        .env("HOME", &home)
        .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
        .output()
        .unwrap();
    let calls = std::fs::read_to_string(home.join("calls")).unwrap_or_default();
    let unit = std::fs::read_to_string(home.join(".config/systemd/user/acpmux.service"))
        .unwrap_or_default();
    let mut units: Vec<String> = std::fs::read_dir(home.join(".config/systemd/user"))
        .map(|dir| dir.filter_map(|e| e.ok()?.file_name().into_string().ok()).collect())
        .unwrap_or_default();
    units.sort();
    let _ = std::fs::remove_dir_all(&home);
    LinuxRun {
        calls: calls.lines().map(str::to_owned).collect(),
        unit,
        units,
        out: String::from_utf8_lossy(&out.stdout).into_owned(),
        err: String::from_utf8_lossy(&out.stderr).into_owned(),
        code: out.status.code(),
    }
}

/// The daemon's unit and, beside it, `host_auto_update`'s timer and its service.
const WITH_TIMER: [&str; 3] = ["acpmux-update.service", "acpmux-update.timer", "acpmux.service"];

impl LinuxRun {
    fn started_by_systemd(&self) -> bool {
        self.out.lines().any(|l| l == SYSTEMD_STARTED)
    }
    fn detached_start(&self) -> bool {
        self.calls.iter().any(|c| c == "acpmux --json daemon start")
    }
}

#[test]
#[cfg(unix)]
fn linux_setup_installs_the_unit_and_hands_a_detached_daemon_to_it() {
    let run = linux_restart_run("setup", true, LINGERING);
    assert_eq!(run.unit, SYSTEMD_UNIT);
    assert_eq!(run.units, WITH_TIMER, "written beside and renamed, nothing left");
    assert!(run.unit.contains("KillMode=process"), "a restart must keep the agent hosts");
    assert_never_gives_up(&run.unit);
    let steps: Vec<&str> = run
        .calls
        .iter()
        .map(String::as_str)
        .filter(|c| {
            // `show`: the timer install asks the manager about its units.
            !c.starts_with("systemctl --user show")
                && !c.starts_with("loginctl")
                && *c != "acpmux --json daemon status"
        })
        .collect();
    assert_eq!(
        steps,
        [
            "systemctl --user daemon-reload",
            "systemctl --user cat acpmux.service",
            "systemctl --user is-active --quiet acpmux.service",
            "acpmux daemon shutdown --keep-agents --restart",
            "systemctl --user enable --now acpmux.service",
            // The self-update timer (host_auto_update.rs), once the unit runs.
            "systemctl --user daemon-reload",
            "systemctl --user enable --now acpmux-update.timer",
        ]
    );
    assert!(run.started_by_systemd());
}

/// A full disk or a crash loop never leaves the unit failed (huge-blue,
/// 2026-10-25: the old start limit left acpmux down for 33 minutes).
fn assert_never_gives_up(unit: &str) {
    let lines: Vec<&str> = unit.lines().collect();
    for key in [
        "StartLimitIntervalSec=0",
        "Restart=always",
        "RestartSec=3",
        "RestartSteps=5",
        "RestartMaxDelaySec=60",
        "KillMode=process",
    ] {
        assert!(lines.contains(&key), "{key} missing:\n{unit}");
    }
    assert!(!unit.contains("StartLimitBurst="), "a start limit gives up:\n{unit}");
    assert!(!unit.contains("MemoryHigh="), "MemoryHigh stalled the daemon for 37 min");
    // `StartLimitIntervalSec=` is a [Unit] key; systemd ignores it under [Service].
    let service = unit.find("[Service]").unwrap();
    assert!(unit.find("StartLimitIntervalSec=0").unwrap() < service, "{unit}");
}

/// Every Linux script parses as POSIX sh (a heredoc after `&&` continues
/// the list past its delimiter line, so the scripts are checked whole).
#[test]
#[cfg(unix)]
fn the_linux_scripts_parse_as_posix_sh() {
    for (name, script) in [
        ("setup", linux_restart(true, true)),
        ("update", linux_restart(false, true)),
        ("refresh", unit_refresh()),
        ("migrate dry", migrate(true)),
        ("migrate", migrate(false)),
    ] {
        for shell in ["sh", "dash", "bash"] {
            let Ok(out) = std::process::Command::new(shell).args(["-n", "-c", &script]).output()
            else {
                continue;
            };
            assert!(
                out.status.success(),
                "{name} under {shell}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
        }
    }
}

#[test]
#[cfg(unix)]
fn linux_update_rewrites_a_unit_an_older_acpmux_wrote_and_keeps_anyone_elses() {
    let host = LinuxHost { installed: true, active: true, ..LINGERING };
    for old in OLD_SYSTEMD_UNITS {
        let run = linux_restart_run(
            "refresh-old",
            false,
            LinuxHost { installed_text: Some(old), ..host },
        );
        assert_eq!(run.unit, SYSTEMD_UNIT, "{}", run.err);
        assert_eq!(run.units, WITH_TIMER, "no temporary unit file is left");
        let reload = run.calls.iter().position(|c| c == "systemctl --user daemon-reload");
        let restart = run.calls.iter().position(|c| c == "systemctl --user restart acpmux.service");
        assert!(reload.is_some() && reload < restart, "reload, then restart: {:?}", run.calls);
        assert!(run.started_by_systemd());
    }
    // Already this build's text: not rewritten, no reload before the
    // restart (the one after it reads the update timer's new units).
    let run = linux_restart_run("refresh-same", false, host);
    assert_eq!(run.unit, SYSTEMD_UNIT);
    let restart = run.calls.iter().position(|c| c == "systemctl --user restart acpmux.service");
    assert!(
        !run.calls[..restart.unwrap_or(run.calls.len())]
            .iter()
            .any(|c| c == "systemctl --user daemon-reload"),
        "{:?}",
        run.calls
    );
    // Someone's own edit of the unit is theirs.
    let edited = "[Service]\nExecStart=%h/.local/bin/acpmux daemon run\nRestart=on-failure\n";
    let run = linux_restart_run(
        "refresh-edited",
        false,
        LinuxHost { installed_text: Some(edited), ..host },
    );
    assert_eq!(run.unit, edited);
    assert!(run.started_by_systemd());
    // systemd does not take the new text: the old one goes back, and the
    // update goes on under it (the next update tries again).
    let run = linux_restart_run(
        "refresh-no-reload",
        false,
        LinuxHost { installed_text: Some(OLD_SYSTEMD_UNITS[0]), reloads: false, ..host },
    );
    assert_eq!(run.unit, OLD_SYSTEMD_UNITS[0]);
    assert!(run.err.contains("did not reload"), "{}", run.err);
    assert!(run.started_by_systemd(), "{:?}", run.calls);
    assert_eq!(run.units, WITH_TIMER, "no temporary unit file is left");
    // Current text that systemd has not read: read before the restart;
    // when that read fails, no restart.
    let run = linux_restart_run("need-reload", false, LinuxHost { need_reload: true, ..host });
    let at = |c: &str| run.calls.iter().position(|x| x == c);
    let reload = at("systemctl --user daemon-reload");
    let restart = at("systemctl --user restart acpmux.service");
    assert!(reload.is_some() && reload < restart, "{:?}", run.calls);
    let run = linux_restart_run(
        "need-reload-fails",
        false,
        LinuxHost { need_reload: true, reloads: false, ..host },
    );
    assert_eq!(run.code, Some(1), "{}", run.err);
    assert!(run.err.contains("did not reload"), "{}", run.err);
    assert!(!run.calls.iter().any(|c| c.contains("restart")), "{:?}", run.calls);
    assert!(!run.started_by_systemd());
    // No reference to compare with (a full /tmp): the unit is not taken as ours.
    let run = linux_restart_run(
        "refresh-no-tmp",
        false,
        LinuxHost { installed_text: Some(OLD_SYSTEMD_UNITS[0]), mktemp: false, ..host },
    );
    assert_eq!(run.unit, OLD_SYSTEMD_UNITS[0]);
    assert!(run.started_by_systemd(), "{:?}", run.calls);
    // The old unit is the one #22899 shipped, the one huge-blue may hold.
    assert!(OLD_SYSTEMD_UNITS[0].contains("StartLimitBurst=5\n"));
    assert!(OLD_SYSTEMD_UNITS.iter().all(|old| *old != SYSTEMD_UNIT));
}

#[test]
#[cfg(unix)]
fn linux_update_restarts_a_running_unit_and_never_starts_a_second_daemon() {
    let run = linux_restart_run("update-active", true, LinuxHost { active: true, ..LINGERING });
    assert!(run.calls.contains(&"systemctl --user restart acpmux.service".to_owned()));
    assert!(
        !run.calls.iter().any(|c| c.starts_with("acpmux ") && c != "acpmux --json daemon status"),
        "{:?}",
        run.calls
    );
    assert!(run.started_by_systemd());
}

#[test]
#[cfg(unix)]
fn linux_falls_back_to_the_detached_start_without_a_unit_a_manager_or_linger() {
    // An update on a host set up before the unit: no unit file.
    let run = linux_restart_run("no-unit", false, LINGERING);
    assert!(run.detached_start() && !run.started_by_systemd(), "{:?}", run.calls);
    assert!(
        !run.calls.iter().any(|c| c.starts_with("loginctl")),
        "an update that does not use the unit leaves linger alone: {:?}",
        run.calls
    );
    // A container without a user manager, even at setup.
    let run = linux_restart_run("no-manager", true, LinuxHost { manager: false, ..LINGERING });
    assert!(run.unit.is_empty() && run.detached_start());
    // No linger and none allowed: the unit would stop at logout.
    let host = LinuxHost { linger: false, linger_allowed: false, ..LINGERING };
    let run = linux_restart_run("no-linger", true, host);
    assert!(run.unit.is_empty() && run.detached_start(), "{:?}", run.calls);
    // Linger off but allowed: turned on, and the unit is used.
    let run = linux_restart_run("linger-on", true, LinuxHost { linger: false, ..LINGERING });
    assert!(run.calls.contains(&"loginctl enable-linger".to_owned()));
    assert!(run.started_by_systemd());
    // A managed unit that fails to start is reported to the caller; do not
    // spawn a second daemon outside the unit (the lock would loop).
    let run = linux_restart_run("enable-fails", true, LinuxHost { enables: false, ..LINGERING });
    assert!(!run.detached_start() && !run.started_by_systemd(), "{:?}", run.calls);
    assert_ne!(run.code, Some(0));
}

#[test]
#[cfg(unix)]
fn a_daemon_under_another_unit_is_refused_before_anything_stops_it() {
    let host = LinuxHost { daemon_unit: Some("acpmux-agent-huge-blue.service"), ..LINGERING };
    for (tag, install) in [("foreign-setup", true), ("foreign-update", false)] {
        let run = linux_restart_run(tag, install, host);
        assert_eq!(run.code, Some(3));
        assert!(run.err.contains("acpmux-agent-huge-blue.service"), "{}", run.err);
        assert_eq!(
            run.calls,
            [
                "acpmux --json daemon status",
                "systemctl --user show acpmux.service -p MainPID --value",
            ],
            "only read-only ownership probes may run"
        );
        assert!(run.unit.is_empty());
    }
    // The daemon under acpmux.service itself, in a session scope, or in a
    // service that merely started it: no refusal; it is handed to the unit.
    for unit in [
        "acpmux.service",
        "acpmux-update.service",
        "session-4.scope",
        "tmux.service",
        "/system.slice/ssh.service",
        "/system.slice/actions.runner.manaflow-ai.huge-blue.service",
    ] {
        let run =
            linux_restart_run("own-unit", true, LinuxHost { daemon_unit: Some(unit), ..LINGERING });
        assert!(run.started_by_systemd(), "{unit}: {}", run.err);
    }
}

#[test]
#[cfg(unix)]
fn linux_update_of_a_host_set_up_earlier_restarts_its_unit() {
    let host = LinuxHost { installed: true, active: true, ..LINGERING };
    let run = linux_restart_run("update-installed", false, host);
    assert!(run.calls.contains(&"systemctl --user restart acpmux.service".to_owned()));
    assert!(run.started_by_systemd() && !run.detached_start(), "{:?}", run.calls);
    // The restart fails: an error, not a started daemon.
    let run = linux_restart_run("restart-fails", false, LinuxHost { restarts: false, ..host });
    assert_ne!(run.code, Some(0));
    assert!(!run.started_by_systemd() && !run.detached_start(), "{:?}", run.calls);
}

#[test]
#[cfg(unix)]
fn a_daemon_that_outlives_its_shutdown_fails_the_handoff_instead_of_looping_the_unit() {
    let host = LinuxHost {
        installed: true,
        daemon_unit: Some("session-4.scope"),
        survives_shutdown: true,
        ..LINGERING
    };
    let run = linux_restart_run("survives", false, host);
    assert_eq!(run.code, Some(4), "{}", run.err);
    assert!(run.err.contains("did not shut down"), "{}", run.err);
    assert!(
        !run.calls.iter().any(|c| c.starts_with("systemctl --user enable")),
        "the unit must not start against a held lock: {:?}",
        run.calls
    );
    assert!(!run.started_by_systemd() && !run.detached_start());
    assert_never_gives_up(SYSTEMD_UNIT);
}

#[test]
#[cfg(unix)]
fn a_restart_keeps_agents_and_falls_back_only_for_a_cli_without_the_flag() {
    // A current CLI: one call, with the flag.
    assert_eq!(remote_shutdown_calls("new", "exit 0"), ["daemon shutdown --keep-agents --restart"]);
    // A CLI older than the flag: clap refuses it; the plain call detaches.
    let old = r#"case "$*" in *--keep-agents*) echo "error: unexpected argument '--keep-agents' found" >&2; exit 2;; esac"#;
    assert_eq!(
        remote_shutdown_calls("old", old),
        ["daemon shutdown --keep-agents --restart", "daemon shutdown"]
    );
    let previous = r#"case "$*" in *--restart*) echo "error: unexpected argument '--restart' found" >&2; exit 2;; esac"#;
    assert_eq!(
        remote_shutdown_calls("previous", previous),
        ["daemon shutdown --keep-agents --restart", "daemon shutdown --keep-agents"]
    );
    // Any other failure (no daemon answered) is not retried.
    let down = "echo 'acpmux: runtime: daemon not running' >&2; exit 1";
    assert_eq!(remote_shutdown_calls("down", down), ["daemon shutdown --keep-agents --restart"]);
}
