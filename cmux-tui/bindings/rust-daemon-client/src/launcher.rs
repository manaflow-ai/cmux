//! Locates the cmux-tui binary and runs `cmux-tui --session <S> --json server
//! ensure`, which returns the running owner or starts a detached one that
//! outlives the app (the same contract as the Swift app's `DaemonLauncher`).

use std::fs::File;
use std::io::{Read, Seek};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

/// The cmux-tui pin this crate was built against: the hosted daemon binary
/// cmux-next bundles (`scripts/cmux-next/cmux-tui.pin` in manaflow-ai/cmux, the
/// same commit as this crate and the SDK it depends on by path).
pub const PIN: &str = include_str!("../../../../scripts/cmux-next/cmux-tui.pin");

/// Dev override for the binary path.
pub const BINARY_ENV: &str = "CMUX2_TUI_BIN";

fn pin_field(key: &str) -> Option<&'static str> {
    PIN.lines().find_map(|line| line.strip_prefix(key)?.strip_prefix('='))
}

/// The pinned cmux-tui commit.
pub fn pinned_commit() -> &'static str {
    pin_field("commit").unwrap_or("unknown")
}

/// Where `scripts/fetch-cmux-tui.sh` stores the pinned hosted binary:
/// `<cache>/cmux2/cmux-tui/<commit>/cmux-tui`.
pub fn pinned_cache_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let cache = if cfg!(target_os = "macos") {
        home?.join("Library/Caches")
    } else if cfg!(windows) {
        PathBuf::from(std::env::var_os("LOCALAPPDATA")?)
    } else {
        std::env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .or_else(|| home.map(|h| h.join(".cache")))?
    };
    let exe = if cfg!(windows) { "cmux-tui.exe" } else { "cmux-tui" };
    Some(cache.join("cmux2/cmux-tui").join(pinned_commit()).join(exe))
}

/// Binary lookup: `$CMUX2_TUI_BIN`, then next to the app (`Contents/Resources/
/// bin/cmux-tui` in a macOS bundle, `cmux-tui` beside the executable
/// elsewhere), then the pinned dev cache.
pub fn resolve_binary() -> Result<PathBuf, LaunchError> {
    let mut searched = Vec::new();
    let mut candidates = Vec::new();
    if let Some(path) = std::env::var_os(BINARY_ENV).filter(|p| !p.is_empty()) {
        candidates.push(PathBuf::from(path));
    }
    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
    {
        candidates.push(dir.join("../Resources/bin/cmux-tui"));
        candidates.push(dir.join(if cfg!(windows) { "cmux-tui.exe" } else { "cmux-tui" }));
    }
    candidates.extend(pinned_cache_path());
    for candidate in candidates {
        if is_executable(&candidate) {
            return Ok(candidate);
        }
        searched.push(candidate);
    }
    Err(LaunchError::BinaryNotFound(searched))
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata().is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

#[derive(Debug)]
pub enum LaunchError {
    BinaryNotFound(Vec<PathBuf>),
    Spawn(std::io::Error),
    Timeout(Duration),
    Failed { status: Option<i32>, output: String },
    Parse(String),
}

impl std::fmt::Display for LaunchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BinaryNotFound(searched) => write!(
                f,
                "cmux-tui not found (set {BINARY_ENV} or run scripts/fetch-cmux-tui.sh); searched {searched:?}"
            ),
            Self::Spawn(e) => write!(f, "cannot run cmux-tui: {e}"),
            Self::Timeout(t) => write!(f, "cmux-tui server ensure did not finish within {t:?}"),
            Self::Failed { status, output } => {
                write!(f, "cmux-tui server ensure failed ({status:?}): {output}")
            }
            Self::Parse(s) => write!(f, "unexpected server ensure output: {s}"),
        }
    }
}

impl std::error::Error for LaunchError {}

/// `server ensure --json` result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EnsureResult {
    /// `"running"` or `"started"`.
    pub status: String,
    pub session: String,
    pub socket: PathBuf,
    pub pid: u32,
    pub generation: String,
}

#[derive(Clone, Debug)]
pub struct Launcher {
    pub binary: PathBuf,
    pub session: String,
    /// `CMUX_TUI_STATE_DIR` for the owner; `None` keeps cmux-tui's default.
    pub state_dir: Option<PathBuf>,
    /// `--terminal-reap-grace-seconds` (the Swift app uses 30).
    pub terminal_reap_grace_seconds: u32,
    pub timeout: Duration,
}

impl Launcher {
    pub fn new(binary: PathBuf, session: impl Into<String>) -> Self {
        Self {
            binary,
            session: session.into(),
            state_dir: None,
            terminal_reap_grace_seconds: 30,
            timeout: Duration::from_secs(20),
        }
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(&self.binary);
        command.arg("--session").arg(&self.session).arg("--json").args(args);
        if let Some(dir) = &self.state_dir {
            command.env("CMUX_TUI_STATE_DIR", dir);
        }
        // cmux-tui puts sockets under $XDG_RUNTIME_DIR, else $TMPDIR. Pin the
        // base to the per-user temp dir so an app started with another TMPDIR
        // still finds the live owner (same rule as the Swift launcher).
        if let Some(base) = user_temp_dir() {
            command.env_remove("XDG_RUNTIME_DIR").env("TMPDIR", base);
        }
        command
    }

    /// Returns the running owner or starts one. Blocks at most `timeout`.
    pub fn ensure(&self) -> Result<EnsureResult, LaunchError> {
        if let Some(dir) = &self.state_dir {
            std::fs::create_dir_all(dir).map_err(LaunchError::Spawn)?;
        }
        let grace = self.terminal_reap_grace_seconds.to_string();
        let output = run_with_timeout(
            self.command(&["server", "ensure", "--terminal-reap-grace-seconds", &grace]),
            self.timeout,
        )?;
        parse_ensure(&output)
    }

    /// Stops the owner (tests and explicit teardown). `end_terminals` also
    /// ends its terminals instead of keeping them for the next owner.
    pub fn stop(&self, end_terminals: bool) -> Result<String, LaunchError> {
        let mut args = vec!["server", "stop"];
        if end_terminals {
            args.push("--end-terminals");
        }
        run_with_timeout(self.command(&args), self.timeout)
    }
}

/// Parses the last JSON line of `server ensure --json` output.
pub fn parse_ensure(stdout: &str) -> Result<EnsureResult, LaunchError> {
    let line = stdout
        .lines()
        .map(str::trim)
        .rfind(|l| l.starts_with('{'))
        .ok_or_else(|| LaunchError::Parse(stdout.to_string()))?;
    let value: serde_json::Value =
        serde_json::from_str(line).map_err(|e| LaunchError::Parse(format!("{e}: {line}")))?;
    let text = |key: &str| value.get(key).and_then(|v| v.as_str()).map(str::to_string);
    let parsed = (|| {
        Some(EnsureResult {
            status: text("status")?,
            session: text("session")?,
            socket: PathBuf::from(text("socket")?),
            pid: u32::try_from(value.get("pid")?.as_u64()?).ok()?,
            generation: text("generation")?,
        })
    })();
    parsed.ok_or_else(|| LaunchError::Parse(line.to_string()))
}

/// Runs `command` with stdout/stderr in temp files (never pipes: the owner
/// `server ensure` starts inherits them, and a pipe would never reach EOF),
/// waiting on a helper thread with a deadline. Returns stdout on success.
fn run_with_timeout(mut command: Command, timeout: Duration) -> Result<String, LaunchError> {
    let mut stdout = tempfile().map_err(LaunchError::Spawn)?;
    let mut stderr = tempfile().map_err(LaunchError::Spawn)?;
    command
        .stdin(Stdio::null())
        .stdout(stdout.try_clone().map_err(LaunchError::Spawn)?)
        .stderr(stderr.try_clone().map_err(LaunchError::Spawn)?);
    let mut child = command.spawn().map_err(LaunchError::Spawn)?;
    let pid = child.id();
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("cmux-tui-ensure".into())
        .spawn(move || {
            let _ = tx.send(child.wait());
        })
        .map_err(LaunchError::Spawn)?;
    let status = match rx.recv_timeout(timeout) {
        Ok(status) => status.map_err(LaunchError::Spawn)?,
        Err(_) => {
            kill(pid);
            return Err(LaunchError::Timeout(timeout));
        }
    };
    let read = |file: &mut File| {
        let mut s = String::new();
        let _ = file.rewind();
        let _ = file.read_to_string(&mut s);
        s
    };
    let out = read(&mut stdout);
    if !status.success() {
        let err = read(&mut stderr);
        let output = if err.trim().is_empty() { out } else { err };
        return Err(LaunchError::Failed {
            status: status.code(),
            output: output.trim().to_string(),
        });
    }
    Ok(out)
}

fn tempfile() -> std::io::Result<File> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let path = std::env::temp_dir().join(format!(
        "cmux-daemon-client-{}-{}.out",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let file = File::options().read(true).write(true).create_new(true).open(&path)?;
    // Unlinked at once; the open handles keep it alive.
    let _ = std::fs::remove_file(&path);
    Ok(file)
}

fn kill(pid: u32) {
    #[cfg(unix)]
    if let Ok(pid) = i32::try_from(pid) {
        // SAFETY: plain signal to a child we spawned and have not reaped.
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
    }
    #[cfg(windows)]
    {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_TERMINATE, TerminateProcess};
        // SAFETY: plain calls; the handle is checked and closed.
        unsafe {
            let process = OpenProcess(PROCESS_TERMINATE, 0, pid);
            if !process.is_null() {
                TerminateProcess(process, 1);
                CloseHandle(process);
            }
        }
    }
    #[cfg(not(any(unix, windows)))]
    let _ = pid;
}

/// The per-user temp dir on macOS (`_CS_DARWIN_USER_TEMP_DIR`), independent
/// of this process's `TMPDIR`. `None` elsewhere: cmux-tui's own default.
fn user_temp_dir() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        let mut buffer = vec![0u8; 1024];
        // SAFETY: buffer is valid for its length; confstr writes a C string.
        let len = unsafe {
            libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, buffer.as_mut_ptr().cast(), buffer.len())
        };
        if len == 0 || len > buffer.len() {
            return None;
        }
        buffer.truncate(len - 1);
        String::from_utf8(buffer).ok().filter(|s| !s.is_empty()).map(PathBuf::from)
    }
    #[cfg(not(target_os = "macos"))]
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ensure_output() {
        let out = r#"{"generation":"c282d03b-19e7-4ced-9c12-bebc45bbe532","message":"local server started","pid":66033,"session":"s","socket":"/tmp/cmux-tui-501/s.sock","status":"started"}"#;
        let parsed = parse_ensure(&format!("noise\n{out}\n")).unwrap();
        assert_eq!(parsed.status, "started");
        assert_eq!(parsed.pid, 66033);
        assert_eq!(parsed.socket, PathBuf::from("/tmp/cmux-tui-501/s.sock"));
        assert!(parse_ensure("nope").is_err());
    }

    #[test]
    fn pin_names_a_commit() {
        assert_eq!(pinned_commit().len(), 40);
        let exe = if cfg!(windows) { "cmux-tui.exe" } else { "cmux-tui" };
        assert!(pinned_cache_path().unwrap().ends_with(Path::new(pinned_commit()).join(exe)));
    }
}
