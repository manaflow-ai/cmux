//! What stops the daemon besides a client: a signal, and the store asking for a restart (moved
//! out of `daemon.rs`, which is over its size budget).

/// Aborts a task when dropped.
pub(super) struct AbortOnDrop(pub(super) tokio::task::AbortHandle);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Resolves, with the reason logged, once the store asks the daemon to stop
/// (`Store::stop_reason`); never for a store that does not ask, or once the store is gone.
pub(super) async fn store_asks_to_stop(
    reason: Option<tokio::sync::watch::Receiver<Option<String>>>,
) {
    let Some(mut reason) = reason else { return std::future::pending().await };
    match reason.wait_for(Option::is_some).await {
        Ok(why) => {
            tracing::error!("stopping for a restart: {}", why.as_deref().unwrap_or_default());
        }
        Err(_) => std::future::pending().await,
    }
}

/// The next delivery of a registered signal; never, if registration failed.
#[cfg(unix)]
pub(super) async fn next_signal(stream: Option<&mut tokio::signal::unix::Signal>) {
    match stream {
        Some(stream) => {
            stream.recv().await;
        }
        None => std::future::pending::<()>().await,
    }
}
