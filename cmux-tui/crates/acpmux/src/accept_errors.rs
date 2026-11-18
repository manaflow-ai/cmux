//! What a failed `accept` on a listener means: retry now, pause, or stop (`server`, the Linux
//! sandbox proxy and the tailnet ingress).

/// How long to wait after a failed `accept`. A connection that died in the queue is gone, so the
/// next accept can run at once; anything else (EMFILE, ENFILE, ENOBUFS) leaves the connection
/// queued, and an immediate retry would spin a core and flood the log until descriptors free up.
pub(crate) fn accept_retry_delay(error: &std::io::Error) -> std::time::Duration {
    use std::io::ErrorKind::{ConnectionAborted, ConnectionReset, Interrupted};
    match error.kind() {
        ConnectionAborted | ConnectionReset | Interrupted => std::time::Duration::ZERO,
        _ => std::time::Duration::from_millis(100),
    }
}

/// Whether a failed `accept` means the listener itself is gone (closed, never listening or not a
/// socket), so a retry can never succeed. Any other failure is about one connection or a passing
/// shortage, and the loop pauses ([`accept_retry_delay`]) and accepts again.
/// Its callers are the Linux sandbox proxy and the tailnet ingress.
#[cfg_attr(not(any(target_os = "linux", feature = "tailnet")), allow(dead_code))]
pub(crate) fn accept_ends_listener(error: &std::io::Error) -> bool {
    #[cfg(unix)]
    if matches!(error.raw_os_error(), Some(libc::EBADF | libc::EINVAL | libc::ENOTSOCK)) {
        return true;
    }
    error.kind() == std::io::ErrorKind::UnexpectedEof
}

#[cfg(test)]
#[path = "accept_errors_tests.rs"]
mod tests;
