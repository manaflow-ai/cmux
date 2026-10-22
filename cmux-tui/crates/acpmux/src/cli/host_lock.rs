//! The host's update lock: one update at a time changes a host's binary,
//! its `acpmux.prev` and its daemon, whether it comes from the host's own
//! timer (`host self-update`, `host_self_update.rs`) or from another machine
//! over ssh (`host update`, `host setup`, `host enroll --fix`).
//!
//! The lock is a lease on the host, checked on the host by every step: the
//! file `update.owner` in [`REMOTE_HOME`] names the update that holds it (a
//! random token) and the process that keeps it (a pid), and a lease whose
//! process ended is free. A remote update keeps it with a script that runs
//! for the update's length ([`lock_updates`]), so a dropped connection ends
//! it; the self-update with its own process. Every script an update runs is
//! fenced ([`Fenced`]): under a flock on `update.lock` it first checks that
//! the lease is still its own, and runs only then, so an update whose lease
//! went (its connection dropped) changes nothing more, and no step of
//! another update runs between that check and the step's end.

use super::{REMOTE_HOME, Remote, RemoteOut};
use anyhow::{Context, Result, anyhow};
use std::path::{Path, PathBuf};
use std::process::Child;

/// What the holder script prints once the lease is this update's, and when
/// another update holds it.
const UPDATE_LOCKED: &str = "ACPMUX_UPDATE_LOCKED";
const UPDATE_RUNNING: &str = "ACPMUX_UPDATE_RUNNING";

/// What a fenced step prints, alone on a line, when the lease is not its
/// update's: it ran nothing.
const LOCK_LOST: &str = "ACPMUX_UPDATE_LOCK_LOST";

/// The lease file, in the acpmux home: `<token> <pid>`.
pub(super) const OWNER: &str = "update.owner";

/// `acpmux_lk SECONDS`: a flock on descriptor 9 (`update.lock`), waiting up
/// to SECONDS (0: not at all), by util-linux's `flock(1)`, else perl's flock
/// (macOS). A host with neither locks nothing (it runs no
/// acpmux-update.timer: systemd needs util-linux); the lease still applies.
const LOCK_FN: &str = r#"acpmux_lk() { if command -v flock >/dev/null 2>&1; then if [ "$1" = 0 ]; then flock -n 9; else flock -w "$1" 9; fi; elif command -v perl >/dev/null 2>&1; then perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or exit 1; $SIG{ALRM} = sub { exit 1 }; alarm($ARGV[0]); flock($f, $ARGV[0] ? LOCK_EX : LOCK_EX | LOCK_NB) or exit 1' "$1"; fi; }
"#;

/// Sets `$acpmux_o` to the lease (`<token> <pid>`); succeeds when its
/// process runs (`kill -0`: a process of this user).
fn lease_held() -> String {
    format!(
        r#"acpmux_o=$(cat {REMOTE_HOME}/{OWNER} 2>/dev/null); [ -n "${{acpmux_o#* }}" ] && [ "${{acpmux_o#* }}" != "$acpmux_o" ] && kill -0 "${{acpmux_o#* }}" 2>/dev/null"#
    )
}

/// The script that takes and keeps the lease for `token`: under the flock
/// (not waited for: one held means an update is at a step), a lease whose
/// process runs is another update's; else this script's pid becomes the
/// lease's, and it runs until its stdin closes (or its connection drops),
/// then gives the lease back.
fn hold_lease(token: &str) -> String {
    let held = lease_held();
    format!(
        r#"mkdir -p {REMOTE_HOME} && exec 9>>{REMOTE_HOME}/update.lock || exit 1
{LOCK_FN}acpmux_lk 0 || {{ echo {UPDATE_RUNNING}; exit 0; }}
if {held}; then echo {UPDATE_RUNNING}; exit 0; fi
printf '%s %s\n' {token} $$ > {REMOTE_HOME}/{OWNER}.$$ && mv -f {REMOTE_HOME}/{OWNER}.$$ {REMOTE_HOME}/{OWNER} || exit 1
exec 9>&-
echo {UPDATE_LOCKED}
cat >/dev/null
acpmux_o=$(cat {REMOTE_HOME}/{OWNER} 2>/dev/null); [ "${{acpmux_o%% *}}" != {token} ] || rm -f {REMOTE_HOME}/{OWNER}"#
    )
}

/// `script` fenced for the lease `token`: under the flock (waited for up to
/// a minute: another update's step, or its lease being taken), it runs only
/// while the lease is `token`'s and its process runs, else prints
/// [`LOCK_LOST`] and exits 75. The script runs without the flock's
/// descriptor, so a daemon it starts does not keep the flock.
fn fence(token: &str, script: &str) -> String {
    let held = lease_held();
    format!(
        r#"mkdir -p {REMOTE_HOME} && exec 9>>{REMOTE_HOME}/update.lock && {{
{LOCK_FN}acpmux_lk 60 && {held} && [ "${{acpmux_o%% *}}" = {token} ]
}} || {{ echo {LOCK_LOST}; echo "this update no longer holds the host's update lock, so it changes nothing more: another update may run" >&2; exit 75; }}
{{
{script}
}} 9>&-"#
    )
}

/// A random lease token: 32 hex digits.
fn new_token() -> Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|e| anyhow!("the OS random generator: {e}"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// Why a fenced script ran nothing: its update's lease went.
#[derive(Debug)]
pub(crate) struct LockLost(String);

impl std::fmt::Display for LockLost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{} lost its update lock (the connection that kept it ended, or another update took it), so this update changes nothing more there",
            self.0
        )
    }
}

impl std::error::Error for LockLost {}

/// The script inside a [`fence`]d one, for tests that answer scripts by
/// their text.
#[cfg(test)]
pub(crate) fn unfence(script: &str) -> Option<&str> {
    const BODY: &str = "exit 75; }\n{\n";
    let start = script.find(BODY)? + BODY.len();
    script.strip_suffix("\n} 9>&-")?.get(start..)
}

/// A host whose every script is fenced for a lease ([`fence`]); a script
/// that found the lease gone fails with [`LockLost`], so the update stops
/// there.
pub(crate) struct Fenced<'a> {
    inner: &'a dyn Remote,
    token: &'a str,
}

impl Remote for Fenced<'_> {
    fn host(&self) -> &str {
        self.inner.host()
    }

    fn exec(&self, script: &str, stdin: Option<&[u8]>) -> Result<RemoteOut> {
        let out = self.inner.exec(&fence(self.token, script), stdin)?;
        if out.stdout.lines().any(|l| l.trim() == LOCK_LOST) {
            return Err(LockLost(self.inner.host().to_owned()).into());
        }
        Ok(out)
    }

    fn push(&self, local: &Path, remote: &str) -> Result<()> {
        self.inner.push(local, remote)
    }

    fn spawn(&self, script: &str) -> Result<Child> {
        self.inner.spawn(script)
    }
}

/// The lease of an update from another machine, kept by [`hold_lease`]
/// running there until this is dropped.
pub(crate) struct HostLock {
    child: Child,
    token: String,
}

impl HostLock {
    /// `r` with every script fenced for this lease.
    pub(crate) fn fence<'a>(&'a self, r: &'a dyn Remote) -> Fenced<'a> {
        Fenced { inner: r, token: &self.token }
    }
}

impl Drop for HostLock {
    fn drop(&mut self) {
        drop(self.child.stdin.take());
        let _ = self.child.wait();
    }
}

/// Take the host's update lease, so the binary, `acpmux.prev` and the daemon
/// change for one update at a time: `host self-update` (its timer) holds it
/// while it updates, `host update` from its probe to its check or rollback,
/// `host setup` while it installs, and `host enroll --fix` while it installs
/// or links the binary and while it restarts the daemon. Run their scripts
/// through [`HostLock::fence`]. None while another update holds it; an error
/// when the script did not run.
pub(crate) fn lock_updates(r: &dyn Remote) -> Result<Option<HostLock>> {
    let token = new_token()?;
    let mut child = r.spawn(&hold_lease(&token))?;
    // The first line the script prints of its own (a login shell may print
    // others first); none when it ended without one.
    let held = child.stdout.take().and_then(|out| {
        std::io::BufRead::lines(std::io::BufReader::new(out)).map_while(Result::ok).find_map(
            |line| match line.trim() {
                UPDATE_LOCKED => Some(true),
                UPDATE_RUNNING => Some(false),
                _ => None,
            },
        )
    });
    if held == Some(true) {
        return Ok(Some(HostLock { child, token }));
    }
    drop(child.stdin.take());
    let out = child.wait_with_output().with_context(|| format!("ssh {}", r.host()))?;
    match held {
        Some(_) => Ok(None),
        None => {
            Err(anyhow!("ssh {} failed: {}", r.host(), String::from_utf8_lossy(&out.stderr).trim()))
        }
    }
}

/// [`lock_updates`] for a command that installs: an error while another
/// update holds the lease.
pub(crate) fn lock_to_install(r: &dyn Remote) -> Result<HostLock> {
    lock_updates(r)?.ok_or_else(|| {
        anyhow!(
            "another update of {} is running (its acpmux-update.timer, or a host update): run this again once it ended",
            r.host()
        )
    })
}

/// The lease of `host self-update`, kept by its own process: taken in the
/// acpmux home `home` (`~/.acpmux`) the way [`hold_lease`] takes it, given
/// back when dropped.
pub(crate) struct Lease {
    owner: PathBuf,
    token: String,
}

impl Lease {
    /// The lease, or None while another update holds it.
    pub(crate) fn take(home: &Path) -> Result<Option<Lease>> {
        std::fs::create_dir_all(home).with_context(|| format!("creating {}", home.display()))?;
        let path = home.join("update.lock");
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .with_context(|| format!("opening {}", path.display()))?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            // SAFETY: flock on a descriptor this function owns.
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
                return Ok(None);
            }
        }
        let owner = home.join(OWNER);
        if std::fs::read_to_string(&owner).ok().as_deref().and_then(lease_pid).is_some_and(alive) {
            return Ok(None);
        }
        let token = new_token()?;
        let part = home.join(format!("{OWNER}.{}", std::process::id()));
        std::fs::write(&part, format!("{token} {}\n", std::process::id()))
            .with_context(|| format!("writing {}", part.display()))?;
        std::fs::rename(&part, &owner).with_context(|| format!("writing {}", owner.display()))?;
        drop(file);
        Ok(Some(Lease { owner, token }))
    }

    /// `r` with every script fenced for this lease.
    pub(crate) fn fence<'a>(&'a self, r: &'a dyn Remote) -> Fenced<'a> {
        Fenced { inner: r, token: &self.token }
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        let ours = std::fs::read_to_string(&self.owner)
            .is_ok_and(|text| text.split_whitespace().next() == Some(self.token.as_str()));
        if ours {
            let _ = std::fs::remove_file(&self.owner);
        }
    }
}

/// The pid of a lease file's `<token> <pid>`.
fn lease_pid(text: &str) -> Option<i32> {
    text.split_whitespace().nth(1)?.parse().ok().filter(|pid| *pid > 0)
}

/// Whether a process of this user with `pid` runs, as `kill -0` answers.
fn alive(pid: i32) -> bool {
    #[cfg(unix)]
    {
        // SAFETY: signal 0 checks the pid and sends nothing.
        unsafe { libc::kill(pid, 0) == 0 }
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        false
    }
}
