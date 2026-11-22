//! The daemon an open-source brain needs beside its ACP process, run by the Chief host itself:
//! OpenClaw's Gateway (`openclaw gateway run`) and Hermes' gateway (`hermes gateway run`).
//!
//! Hermes' `acp` process is only a viewer: its sessions belong to a gateway daemon, which the
//! viewer otherwise starts on macOS as a one-off launchd job in the user's GUI domain
//! (hermes_cli/gateway_launchd_runtime.py). That job runs outside the Chief's process tree, and
//! where the GUI domain does not run it every `session/new` answers `storage_unavailable`
//! (cmux-ci steps be2ad7da45a6, 299ab54c8170, eb3f6122e288). Started here first, the viewer
//! finds a ready owner and starts none.
//!
//! Each gateway is a child of the host in its own process group, with only the env it needs
//! (never a provider key of the person's), and ends with the host. A gateway an earlier host
//! left (its pid file) is ended first, but only when that pid is still such a gateway.

use std::ffi::OsString;
use std::io;
use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::session_dir::write_if_changed;

/// The host env keys a brain gateway keeps: the program's own search path and locale, the user,
/// temp, the cmux sockets its `cmux` MCP server talks to, and the container engine's socket.
pub const GATEWAY_ENV: [&str; 13] = [
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "LANG",
    "TMPDIR",
    "DOCKER_HOST",
    "CMUX_TUI_SOCKET",
    "CMUX_MUX_SOCKET",
    "CMUX_SOCKET_PATH",
    "CMUX_APP_DAEMON_SOCKET",
    "CMUX_BUNDLED_CLI_PATH",
    "CMUX_NEXT_CONFIG_FILE",
];

/// How to start one brain's gateway.
pub struct Spec<'a> {
    /// What the log lines call it ("openclaw", "hermes").
    pub name: &'a str,
    /// The brain's program.
    pub program: &'a Path,
    /// The arguments after the program (`gateway run ...`).
    pub args: &'a [&'a str],
    /// A word the running command line holds (the program's name): a pid file's pid is ended
    /// only when its command has it and `gateway run`.
    pub marker: &'a str,
    /// Env beyond [`GATEWAY_ENV`] (the brain's home, its switches).
    pub env: Vec<(String, OsString)>,
    /// Where its pid is kept while it runs.
    pub pid_file: PathBuf,
    /// Its stdout and stderr.
    pub log_file: PathBuf,
}

/// Whether `pid` is still a gateway this host's code started: a process group leader whose
/// command holds `marker` and `gateway run`. A pid the system gave to another program since is
/// never signalled.
pub fn is_our_gateway(pid: i32, marker: &str) -> bool {
    let Ok(out) = std::process::Command::new("/bin/ps")
        .args(["-o", "pgid=,command=", "-p", &pid.to_string()])
        .stdin(std::process::Stdio::null())
        .output()
    else {
        return false;
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut words = text.split_whitespace();
    let leader = words.next().and_then(|g| g.parse::<i32>().ok()) == Some(pid);
    let command: Vec<&str> = words.collect();
    leader
        && command.iter().any(|w| w.contains(marker))
        && command.windows(2).any(|w| w == ["gateway", "run"])
}

/// A brain's gateway: a child of the host, ended (its process group) when the host lets go of it.
pub struct Gateway {
    child: std::process::Child,
    pid_file: PathBuf,
}

impl Gateway {
    pub fn start(spec: Spec<'_>, log: &dyn Fn(String)) -> io::Result<Gateway> {
        if let Some(old) = std::fs::read_to_string(&spec.pid_file)
            .ok()
            .and_then(|p| p.trim().parse::<i32>().ok())
            .filter(|pid| *pid > 1)
            .filter(|pid| is_our_gateway(*pid, spec.marker))
        {
            // Only our own gateway's group: the pid file is in the Chief's own brain home.
            // SAFETY: kill(2) with a negative pid signals that process group; no memory access.
            if unsafe { libc::kill(-old, libc::SIGTERM) } == 0 {
                // Its lock must be free before a new gateway takes it: wait, then kill.
                end_group(old, Duration::from_secs(10));
                log(format!("{}: ended the gateway an earlier host left (pid {old})", spec.name));
            }
        }
        if let Some(dir) = spec.log_file.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let logfile = std::fs::OpenOptions::new().create(true).append(true).open(&spec.log_file)?;
        let keep: Vec<(String, OsString)> = GATEWAY_ENV
            .iter()
            .filter_map(|k| std::env::var_os(k).map(|v| ((*k).to_owned(), v)))
            .collect();
        let child = std::process::Command::new(spec.program)
            .args(spec.args)
            .env_clear()
            .envs(keep)
            .envs(spec.env)
            .stdin(std::process::Stdio::null())
            .stdout(logfile.try_clone()?)
            .stderr(logfile)
            .process_group(0)
            .spawn()?;
        write_if_changed(&spec.pid_file, child.id().to_string().as_bytes())?;
        log(format!("{}: gateway pid {}", spec.name, child.id()));
        Ok(Gateway { child, pid_file: spec.pid_file })
    }

    /// The gateway's process id (its process group).
    pub fn pid(&self) -> u32 {
        self.child.id()
    }

    /// Whether the gateway has exited (with its status).
    fn exited(&mut self) -> Option<std::process::ExitStatus> {
        self.child.try_wait().ok().flatten()
    }
}

/// Whether a process of group `pgid` still exists.
fn group_alive(pgid: i32) -> bool {
    // SAFETY: kill(2) with signal 0 only checks; no memory access.
    unsafe { libc::kill(-pgid, 0) == 0 }
}

/// Waits up to `grace` for group `pgid` (already sent SIGTERM) to go, then kills it.
fn end_group(pgid: i32, grace: Duration) {
    let end = Instant::now() + grace;
    while group_alive(pgid) && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(50));
    }
    if group_alive(pgid) {
        // SAFETY: kill(2) on a process group this host started; no memory access.
        unsafe {
            libc::kill(-pgid, libc::SIGKILL);
        }
    }
}

impl Drop for Gateway {
    fn drop(&mut self) {
        let pid = self.child.id() as i32;
        // SAFETY: kill(2) on the process group this host started; no memory access.
        unsafe {
            libc::kill(-pid, libc::SIGTERM);
        }
        // A gateway that drains slowly never holds the host's exit: 10 s, then SIGKILL.
        let end = Instant::now() + Duration::from_secs(10);
        while self.exited().is_none() && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(50));
        }
        end_group(pid, Duration::ZERO);
        let _ = self.child.wait();
        let _ = std::fs::remove_file(&self.pid_file);
    }
}

/// Whether a process holds `lock` with flock(2) (the way Hermes' gateway holds `gateway.lock`
/// and its own viewer probes it: held means a starting or ready owner, which the viewer waits
/// for instead of starting another).
fn lock_held(lock: &Path) -> bool {
    use std::os::fd::AsRawFd as _;
    let Ok(file) = std::fs::OpenOptions::new().read(true).write(true).open(lock) else {
        return false;
    };
    // SAFETY: flock(2) on a file descriptor this function owns; no memory access.
    let taken = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0;
    if taken {
        // SAFETY: as above; the probe gives the lock straight back.
        unsafe {
            libc::flock(file.as_raw_fd(), libc::LOCK_UN);
        }
    }
    !taken
}

/// The Chief's Hermes gateway rendezvous dir, under its Hermes home (acpmux uses the same name).
pub const HERMES_LOCK_DIR: &str = "gateway-locks";

/// How long Hermes' gateway may take to hold its lock (a cold Python start is 10-20 s).
pub const HERMES_READY: Duration = Duration::from_secs(90);

/// Starts Hermes' gateway for the Chief's Hermes home (`hermes gateway run --quiet`, no idle
/// exit: it lives as long as this host) and returns once it holds `gateway.lock`, so the first
/// turn's viewer finds it and starts no launchd job of its own. A gateway that exits or does not
/// hold the lock within `ready` is an error (the host marks Hermes unavailable).
pub fn start_hermes(hermes: &Path, home: &Path, log: &dyn Fn(String)) -> io::Result<Gateway> {
    start_hermes_within(hermes, home, HERMES_READY, log)
}

pub fn start_hermes_within(
    hermes: &Path,
    home: &Path,
    ready: Duration,
    log: &dyn Fn(String),
) -> io::Result<Gateway> {
    let mut gateway = start_hermes_now(hermes, home, log)?;
    let lock = home.join("gateway.lock");
    let end = Instant::now() + ready;
    // A bounded poll, not a sleep for timing: Hermes' gateway prints no ready line (it runs
    // quiet) and its readiness is a held flock on gateway.lock, which has no change event
    // (kqueue sees the file's writes, not who holds a lock). Every 200 ms within `ready` (90 s).
    loop {
        if let Some(status) = gateway.exited() {
            return Err(io::Error::other(format!(
                "it exited before it was ready ({status}; see {})",
                home.join("logs").join("chief-gateway.log").display()
            )));
        }
        if lock_held(&lock) {
            return Ok(gateway);
        }
        if Instant::now() >= end {
            return Err(io::Error::other(format!(
                "it did not hold its gateway.lock within {} s",
                ready.as_secs()
            )));
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn start_hermes_now(hermes: &Path, home: &Path, log: &dyn Fn(String)) -> io::Result<Gateway> {
    Gateway::start(
        Spec {
            name: "hermes",
            program: hermes,
            args: &["gateway", "run", "--quiet"],
            marker: "hermes",
            env: vec![
                ("HERMES_HOME".to_owned(), home.as_os_str().to_owned()),
                // Hermes serves every profile of an OS user from one gateway found here: the
                // Chief's own dir, the one acpmux gives the Chief's `hermes acp` viewer
                // (chief_builtins.rs brain_side_env), never the user's own Hermes gateway.
                ("HERMES_GATEWAY_LOCK_DIR".to_owned(), home.join(HERMES_LOCK_DIR).into_os_string()),
                ("DO_NOT_TRACK".to_owned(), "1".into()),
            ],
            pid_file: home.join("chief-gateway.pid"),
            log_file: home.join("logs").join("chief-gateway.log"),
        },
        log,
    )
}
