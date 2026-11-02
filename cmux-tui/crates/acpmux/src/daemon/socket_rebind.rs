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
    let bound = Owned::now(&[socket]);
    if bound.is_none() && socket.is_absolute() {
        anyhow::bail!("{} went away as it was bound again", socket.display());
    }
    Ok((listener, bound))
}

/// Serve `listener`, and each listener `swap` brings in its place. Connections already accepted
/// keep running; only the old listener is closed.
pub(super) async fn serve(
    hub: Arc<crate::hub::Hub>,
    listener: UnixListener,
    mut swap: mpsc::Receiver<UnixListener>,
) -> anyhow::Result<()> {
    let mut serving = tokio::spawn(crate::server::serve_unix(hub.clone(), listener));
    loop {
        tokio::select! {
            served = &mut serving => return served?,
            next = swap.recv() => match next {
                Some(listener) => {
                    serving.abort();
                    let _ = (&mut serving).await;
                    serving = tokio::spawn(crate::server::serve_unix(hub.clone(), listener));
                }
                None => return serving.await?,
            },
        }
    }
}
