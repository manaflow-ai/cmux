//! Windows: the router runs in a kill-on-close job object this daemon
//! holds (`daemon/windows.rs` spawn_router). When the daemon's last handle
//! to the job closes (any exit: shutdown, taskkill /F, a crash), Windows
//! ends the router.

use super::{RouterOwner, ask_router};
use crate::config::home;

/// The job the router this daemon started runs in.
pub(super) struct JobOwner {
    _job: crate::job::Job,
}

impl RouterOwner for JobOwner {
    /// A router that already answers belongs to no live daemon of this home
    /// (its own daemon's job would have ended it), so it is told to stop;
    /// the new router waits on router.lock until it has exited.
    fn ensure() -> Option<Self> {
        if ask_router(b"{\"op\":\"status\"}\n").is_ok() {
            let _ = ask_router(b"{\"op\":\"shutdown\"}\n");
        }
        match crate::daemon::windows::spawn_router(&home(), crate::hub::build()) {
            Ok(job) => Some(JobOwner { _job: job }),
            Err(e) => {
                tracing::warn!("could not start the local router: {e}");
                None
            }
        }
    }

    /// No agent outlives a Windows daemon, so the router stops either way:
    /// asked first, then the job's last handle closes.
    fn release(self, _stop: bool) {
        let _ = ask_router(b"{\"op\":\"shutdown\"}\n");
        drop(self);
    }
}
