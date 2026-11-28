//! How an agent's processes end, and the error of one that did not start (the agent itself
//! is in the parent module).

use super::*;

/// SIGKILL to an agent's process group once dropped: at the end of `ChildAgent::terminate`'s
/// grace, or earlier when its caller drops the terminate future after the SIGTERM went out.
#[cfg(unix)]
pub(super) struct KillGroupOnDrop(pub(super) Option<i32>);

#[cfg(unix)]
impl Drop for KillGroupOnDrop {
    fn drop(&mut self) {
        if let Some(pg) = self.0 {
            unsafe {
                libc::killpg(pg, libc::SIGKILL);
            }
        }
    }
}

/// The processes under a direct agent, by pid and start time, taken before
/// its group is signalled: a helper the harness moved out of its group
/// (setsid, Node's `detached: true`) is out of reach of the group signal
/// and runs on with parent pid 1 once the harness is gone (cx-n3uid). The
/// pid is read only while the agent is not reaped (`Child::id` is Some), so
/// it cannot name a reused pid. Not reached, as in `terminate_unadoptable`:
/// a helper that already has ppid 1 (a double fork) or starts after this.
#[cfg(unix)]
pub(super) async fn under_unreaped(child: Option<&Child>) -> Vec<crate::agent_host::tree::Started> {
    let Some(pid) = child.and_then(Child::id) else { return Vec::new() };
    tokio::task::spawn_blocking(move || crate::agent_host::tree::descendants(&[pid]))
        .await
        .unwrap_or_default()
}

/// SIGKILL each of `procs` that still runs as the same process: what the
/// group signal of a direct agent did not reach.
#[cfg(unix)]
pub(super) async fn end_still_running(procs: Vec<crate::agent_host::tree::Started>) {
    if procs.is_empty() {
        return;
    }
    let _ =
        tokio::task::spawn_blocking(move || crate::agent_host::tree::kill_still_running(&procs))
            .await;
}

/// Debug builds only: `ACPMUX_TEST_READER_STOP_HOLD_MS` holds a host link's reader once it stopped,
/// before it marks the link stopped, as a busy runtime does, so the daemon's integration tests
/// can reattach the link meanwhile. Bounded; release builds have no seam.
#[cfg(debug_assertions)]
pub(super) async fn reader_stop_hold() {
    if let Some(ms) =
        std::env::var("ACPMUX_TEST_READER_STOP_HOLD_MS").ok().and_then(|v| v.parse::<u64>().ok())
    {
        tokio::time::sleep(std::time::Duration::from_millis(ms.min(10_000))).await;
    }
}

/// Debug builds only: `ACPMUX_TEST_ACK_FAILS_ONCE=TEXT` fails the acknowledgement of the first
/// host entry whose text holds TEXT, once per process, as a link whose writer stopped first does:
/// the reader stops while the socket still looks open. Release builds have no seam.
#[cfg(debug_assertions)]
pub(super) fn ack_fails_once(entry: &crate::agent_host::Entry) -> bool {
    use crate::agent_host::Entry;
    static FIRED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    let Ok(text) = std::env::var("ACPMUX_TEST_ACK_FAILS_ONCE") else { return false };
    let msg = match entry {
        Entry::Tap { msg, .. } | Entry::In { msg } => msg.to_string(),
        _ => return false,
    };
    msg.contains(&text) && !FIRED.swap(true, Ordering::SeqCst)
}

/// The error of an agent (or its agent host) that did not start; `what` says which, e.g.
/// "spawn agent claude". Out of descriptors, the bare "Too many open files (os error 24)"
/// read like the agent's fault (cmux16, 2026-10-22): say it is the daemon's, with its limit
/// and what to do.
pub(crate) fn spawn_error(what: &str, e: std::io::Error) -> anyhow::Error {
    #[cfg(unix)]
    if matches!(e.raw_os_error(), Some(libc::EMFILE | libc::ENFILE)) {
        let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        let limit = if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) } == 0 {
            format!(" (its limit is {})", lim.rlim_cur)
        } else {
            String::new()
        };
        return anyhow!(
            "{what}: the acpmux daemon is out of open files{limit}; \
             `acpmux daemon shutdown` stops it and the next acpmux command starts it again: {e}"
        );
    }
    anyhow::Error::new(e).context(what.to_owned())
}
