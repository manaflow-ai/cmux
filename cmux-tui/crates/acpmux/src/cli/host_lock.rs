//! The host's update lock, `~/.acpmux/update.lock`: one update at a time
//! changes a host's binary, its `acpmux.prev` and its daemon, whether it
//! comes from the host's own timer (`host self-update`, which takes the flock
//! in its own process, `host_self_update.rs`) or from another machine over
//! ssh (`host update`, `host setup`, `host enroll --fix`, here).

use super::{REMOTE_HOME, Remote};
use anyhow::{Context, Result, anyhow};
use std::process::Child;

/// What [`hold_update_lock`] prints once it holds the lock, and when another
/// update holds it.
const UPDATE_LOCKED: &str = "ACPMUX_UPDATE_LOCKED";
const UPDATE_RUNNING: &str = "ACPMUX_UPDATE_RUNNING";

/// The script that holds the host's update lock, `update.lock` in
/// [`REMOTE_HOME`], until its stdin closes (an ssh that ends closes it too):
/// the flock `host self-update` takes on the host (`host_self_update.rs`),
/// here by util-linux's `flock(1)`, else perl's flock (macOS). A host with
/// neither is not locked: it runs no acpmux-update.timer (systemd needs
/// util-linux), so no self-update races the update.
fn hold_update_lock() -> String {
    format!(
        r#"mkdir -p {REMOTE_HOME} && exec 9>>{REMOTE_HOME}/update.lock || exit 1
if command -v flock >/dev/null 2>&1; then flock -n 9 || {{ echo {UPDATE_RUNNING}; exit 0; }}
elif command -v perl >/dev/null 2>&1; then perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or exit 1; flock($f, LOCK_EX | LOCK_NB) or exit 1' || {{ echo {UPDATE_RUNNING}; exit 0; }}
fi
echo {UPDATE_LOCKED}
exec cat >/dev/null"#
    )
}

/// The host's update lock, held by [`hold_update_lock`] running there until
/// this is dropped.
pub(crate) struct HostLock(Child);

impl Drop for HostLock {
    fn drop(&mut self) {
        drop(self.0.stdin.take());
        let _ = self.0.wait();
    }
}

/// Take the host's update lock, so the binary, `acpmux.prev` and the daemon
/// change for one update at a time: `host self-update` (its timer) holds it
/// while it updates, `host update` from its probe to its check or rollback,
/// and `host setup` and `host enroll --fix` while they push the binary and
/// while they restart the daemon. None while another update holds it; an
/// error when the script did not run.
pub(crate) fn lock_updates(r: &dyn Remote) -> Result<Option<HostLock>> {
    let mut child = r.spawn(&hold_update_lock())?;
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
        return Ok(Some(HostLock(child)));
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
/// update holds the lock.
pub(super) fn lock_to_install(r: &dyn Remote) -> Result<HostLock> {
    lock_updates(r)?.ok_or_else(|| {
        anyhow!(
            "another update of {} is running (its acpmux-update.timer, or a host update): run this again once it ended",
            r.host()
        )
    })
}
