//! The host's update lock: one update at a time changes a host's binary,
//! its `acpmux.prev` and its daemon (`host update`, `host setup`, `host
//! enroll --fix`, each over ssh from another machine).
//!
//! The lock is a lease on the host, checked on the host by every step: the
//! file `update.owner` in [`REMOTE_HOME`] names the update that holds it (a
//! random token), and the process that keeps it holds a flock on
//! `update.lease` for its whole life, so the lease is free once that
//! process ends, however it ends (the kernel drops the flock; a pid in a
//! file could name another process by then). An update keeps it with a
//! script that runs for the update's length ([`lock_updates`]), so a
//! dropped connection ends it. Every script an update runs is fenced
//! ([`Fenced`]): under a flock on `update.lock` it first checks that the
//! lease is still its own, and runs only then, so an update whose lease
//! went (its connection dropped) changes nothing more, and no step of
//! another update runs between that check and the step's end. Its uploads
//! go to names of its own and are moved in place by a fenced step.

use super::{REMOTE_HOME, Remote, RemoteOut};
use anyhow::{Context, Result, anyhow};
use std::path::Path;
use std::process::Child;

/// What the holder script prints once the lease is this update's, and when
/// another update holds it.
const UPDATE_LOCKED: &str = "ACPMUX_UPDATE_LOCKED";
const UPDATE_RUNNING: &str = "ACPMUX_UPDATE_RUNNING";

/// What a fenced step prints, alone on a line, when the lease is not its
/// update's: it ran nothing.
const LOCK_LOST: &str = "ACPMUX_UPDATE_LOCK_LOST";

/// The lease file, in the acpmux home: `<token> <pid>`, the pid for a
/// person reading it (the flock on `update.lease` says whether it is held).
pub(super) const OWNER: &str = "update.owner";

/// `acpmux_lk SECONDS FD`: a flock on descriptor FD, waiting up to SECONDS
/// (0: not at all), by util-linux's `flock(1)`, else perl's flock (macOS).
/// The flock stays with the shell's descriptor once the tool exits. A host
/// with neither fails the script (exit 1) before it changes anything: two
/// updates of it could not be kept apart.
const LOCK_FN: &str = r#"acpmux_lk() { if command -v flock >/dev/null 2>&1; then if [ "$1" = 0 ]; then flock -n "$2"; else flock -w "$1" "$2"; fi; else perl -MFcntl=:flock -e 'open(my $f, ">&=", 0 + $ARGV[1]) or exit 1; $SIG{ALRM} = sub { exit 1 }; alarm($ARGV[0]); flock($f, $ARGV[0] ? LOCK_EX : LOCK_EX | LOCK_NB) or exit 1' "$1" "$2"; fi; }
command -v flock >/dev/null 2>&1 || command -v perl >/dev/null 2>&1 || { echo "this host has neither flock nor perl, so acpmux cannot keep two updates of it apart: install one (util-linux's flock, or perl)" >&2; exit 1; }
"#;

/// Opens `update.lock` as descriptor 9 (held by a step, or while the lease
/// is taken) and `update.lease` as 8 (held by the lease's process).
fn open_locks() -> String {
    format!(
        "mkdir -p {REMOTE_HOME} && exec 9>>{REMOTE_HOME}/update.lock 8>>{REMOTE_HOME}/update.lease"
    )
}

/// The script that takes and keeps the lease for `token`: under the flock
/// (not waited for: one held means an update is at a step), a lease whose
/// flock is held is another update's; else this script holds that flock,
/// writes the lease, and runs until its stdin closes (or its connection
/// drops), then gives the lease back.
fn hold_lease(token: &str) -> String {
    let open = open_locks();
    format!(
        r#"{open} || exit 1
{LOCK_FN}acpmux_lk 0 9 && acpmux_lk 0 8 || {{ echo {UPDATE_RUNNING}; exit 0; }}
printf '%s %s\n' {token} $$ > {REMOTE_HOME}/{OWNER}.$$ && mv -f {REMOTE_HOME}/{OWNER}.$$ {REMOTE_HOME}/{OWNER} || exit 1
exec 9>&-
echo {UPDATE_LOCKED}
cat >/dev/null 8>&-
acpmux_o=$(cat {REMOTE_HOME}/{OWNER} 2>/dev/null); [ "${{acpmux_o%% *}}" != {token} ] || rm -f {REMOTE_HOME}/{OWNER}"#
    )
}

/// `script` fenced for the lease `token`: under the flock (waited for up to
/// a minute: another update's step, or its lease being taken), it runs only
/// while the lease is `token`'s and its process holds its flock, else
/// prints [`LOCK_LOST`] and exits 75. The script runs without either
/// descriptor, so a daemon it starts keeps neither flock.
fn fence(token: &str, script: &str) -> String {
    let open = open_locks();
    format!(
        r#"{open} && {{
{LOCK_FN}acpmux_lk 60 9 && ! acpmux_lk 0 8 && acpmux_o=$(cat {REMOTE_HOME}/{OWNER} 2>/dev/null) && [ "${{acpmux_o%% *}}" = {token} ]
}} || {{ echo {LOCK_LOST}; echo "this update no longer holds the host's update lock, so it changes nothing more: another update may run" >&2; exit 75; }}
{{
{script}
}} 8>&- 9>&-"#
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
    script.strip_suffix("\n} 8>&- 9>&-")?.get(start..)
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

    /// Copies to a name of this lease's own (`<remote>.<token>`), then moves
    /// it to `remote` in a fenced step: a copy that runs on after its lease
    /// went lands beside, never on, what the update now holding the lease
    /// staged. That step also clears what such copies left.
    fn push(&self, local: &Path, remote: &str) -> Result<()> {
        let staged = format!("{remote}.{}", self.token);
        self.inner.push(local, &staged)?;
        // `find`, not a glob: zsh, a common login shell, fails a glob
        // that matches nothing.
        let (dir, name) = remote.rsplit_once('/').unwrap_or((".", remote));
        let left = format!("{name}.{}", "?".repeat(self.token.len()));
        super::run(
            self,
            &format!(
                "mv -f {staged} {remote} && {{ find {dir} -maxdepth 1 -name '{left}' -exec rm -f '{{}}' + 2>/dev/null; true; }}"
            ),
        )?;
        Ok(())
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
/// change for one update at a time: `host update` holds it from its probe to
/// its check or rollback, `host setup` while it installs, and `host enroll
/// --fix` while it installs or links the binary and while it restarts the
/// daemon. Run their scripts
/// through [`HostLock::fence`]. None while another update holds it; an error
/// when the script did not run, or the host can lock nothing ([`LOCK_FN`]).
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
            "another update of {} is running (a host update, setup or enroll --fix): run this again once it ended",
            r.host()
        )
    })
}
