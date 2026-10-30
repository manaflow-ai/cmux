//! The local router's owner: what ties the router's life to this daemon.
//! One `RouterOwner` trait with one impl per platform, so the daemon only
//! calls `ensure_router` at start and `release_router` at shutdown:
//! - Unix (`fifo.rs`, cx-1rvy): the owner FIFO. The router stops when no
//!   process holds a write end; a kept agent host holds one, so the router
//!   serves it through a daemon restart.
//! - Windows (`job_object.rs`): the router runs in a kill-on-close job
//!   object this daemon holds, so Windows ends it with the daemon, a crash
//!   included. Windows has no agent hosts yet, so nothing else owns it.

use crate::config::home;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

#[cfg(unix)]
mod fifo;
#[cfg(unix)]
use fifo::FifoOwner as Owner;
#[cfg(unix)]
mod users;
#[cfg(unix)]
pub(crate) use fifo::{open_router_owner, router_owner_fifo};
#[cfg(windows)]
mod job_object;
#[cfg(windows)]
use job_object::JobOwner as Owner;

/// This daemon's hold on the local router.
trait RouterOwner: Sized + Send {
    /// Starts the local router, or adopts the one that runs; None when this
    /// daemon holds no router (the reason is logged).
    fn ensure() -> Option<Self>;
    /// The shutdown path. `stop`: no agent of this home was kept.
    fn release(self, stop: bool);
}

static ROUTER: Mutex<Option<Owner>> = Mutex::new(None);

/// Starts or adopts the local router and keeps this daemon's hold on it.
pub(super) fn ensure_router() {
    let Some(owner) = Owner::ensure() else { return };
    let previous = ROUTER.lock().unwrap_or_else(PoisonError::into_inner).replace(owner);
    drop(previous);
}

/// Lets go of the router at shutdown (`stop`: no agent was kept).
pub(super) fn release_router(stop: bool) {
    let owner = ROUTER.lock().unwrap_or_else(PoisonError::into_inner).take();
    if let Some(owner) = owner {
        owner.release(stop);
    }
}

/// The owner FIFO an agent host spawned now should hold. Always the home's
/// FIFO: with no router reading it the host's non-blocking open fails at
/// once, and a router this daemon could not adopt still gets the new host
/// as an owner.
pub(crate) fn router_owner_path() -> Option<PathBuf> {
    #[cfg(unix)]
    {
        Some(router_owner_fifo())
    }
    #[cfg(not(unix))]
    None
}

/// Ask the router's admin socket one line; the reply line as JSON.
fn ask_router(line: &[u8]) -> std::io::Result<Value> {
    use std::io::{BufRead, BufReader, Write};
    let socket = cmux_coderouter::admin_socket_path(&home());
    let stream = crate::router_socket::UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(1)))?;
    let mut writer = stream.try_clone()?;
    writer.write_all(line)?;
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer)?;
    serde_json::from_str(&answer).map_err(std::io::Error::other)
}
