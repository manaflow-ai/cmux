//! A daemon whose socket alone is gone binds it again. Its home and lock are still its own, so
//! the socket path is still its to serve, and every command of this home keeps reaching it there.
//! Stopping, as the home watch did before, left nothing serving the home until the next start;
//! running on with no socket (a daemon whose watch missed the removal) left the lock held by a
//! daemon nothing could reach: every command then waited out its budget on "holds daemon.lock but
//! does not answer", and each new `daemon run` piled up behind the lock (cosmic-gray,
//! 2026-11-02).
//!
//! Bounded: each re-bind answers one loss the home watch saw (an event, never a timer), and a
//! daemon binds again at most [`MAX_REBINDS`] times; past that, or when the bind fails (another
//! daemon serves the path now, the folder is another one), it stops as on any other loss.

use super::home_watch::Owned;
use std::path::Path;
use std::sync::Arc;
use tokio::net::UnixListener;
use tokio::sync::mpsc;

/// How many times one daemon binds its socket again before a further loss stops it.
pub(super) const MAX_REBINDS: u32 = 5;

/// Bind `socket` again for the daemon that holds this home's lock (`held`: its home and lock as
/// it first held them). The listener and the socket's identity as bound now, for the next watch.
pub(super) async fn rebind(
    held: Option<&Owned>,
    socket: &Path,
) -> anyhow::Result<(UnixListener, Option<Owned>)> {
    if let Some(why) = held.and_then(Owned::lost) {
        anyhow::bail!("{why}");
    }
    let listener = crate::server::bind_unix(socket).await?;
    // The listener a restart's exec in place keeps is this one now (`daemon/handoff.rs`).
    super::handoff::keep_unix(std::os::fd::AsRawFd::as_raw_fd(&listener));
    let bound = Owned::now(&[socket]);
    if bound.is_none() && socket.is_absolute() {
        anyhow::bail!("{} went away as it was bound again", socket.display());
    }
    Ok((listener, bound))
}

/// The accept loop serving now. It ends with this task: a restart that execs in place aborts
/// this task to stop accepting at once, and its kept copy of the listener holds new dials in the
/// backlog for the next image (`daemon/handoff.rs`).
struct Serving(tokio::task::JoinHandle<anyhow::Result<()>>);

impl Drop for Serving {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Serve `listener`, and each listener `swap` brings in its place. Connections already accepted
/// keep running; only the old listener is closed.
pub(super) async fn serve(
    hub: Arc<crate::hub::Hub>,
    listener: UnixListener,
    mut swap: mpsc::Receiver<UnixListener>,
    v2: Option<Arc<acpmux_core::life::V2>>,
) -> anyhow::Result<()> {
    let mut serving =
        Serving(tokio::spawn(crate::server::serve_unix_with_v2(hub.clone(), listener, v2.clone())));
    loop {
        tokio::select! {
            served = &mut serving.0 => return served?,
            next = swap.recv() => match next {
                Some(listener) => {
                    serving.0.abort();
                    let _ = (&mut serving.0).await;
                    serving = Serving(tokio::spawn(crate::server::serve_unix_with_v2(hub.clone(), listener, v2.clone())));
                }
                None => return (&mut serving.0).await?,
            },
        }
    }
}
