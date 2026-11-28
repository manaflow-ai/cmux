use super::*;
use std::io::{Error as Io, ErrorKind};

fn connect_failed(kind: ErrorKind) -> anyhow::Error {
    anyhow::Error::new(Io::new(kind, "x")).context("connect /run/acpmux.sock")
}

/// A refused or missing socket is `daemon_unreachable`, whatever the words say.
#[test]
fn a_refused_or_missing_socket_is_daemon_unreachable() {
    for kind in [ErrorKind::ConnectionRefused, ErrorKind::NotFound] {
        let app = classify(&connect_failed(kind));
        assert_eq!(app.detail, "daemon_unreachable");
        assert_eq!(app.code, Code::Runtime);
    }
}

/// A timed-out io error never reads as a gone daemon even when its text names the daemon.
#[test]
fn a_timed_out_io_error_is_slow_not_unreachable() {
    let e = anyhow::Error::new(Io::new(ErrorKind::TimedOut, "no reply")).context("daemon status");
    let app = classify(&e);
    assert_eq!(app.code, Code::Timeout);
    assert_eq!(app.detail, "timeout");
    assert!(app.retryable);
}

/// An elapsed tokio timeout is a timeout even when its context has no timeout word.
#[tokio::test]
async fn an_elapsed_bound_is_a_timeout() {
    let elapsed = tokio::time::timeout(std::time::Duration::ZERO, std::future::pending::<()>())
        .await
        .unwrap_err();
    let e = anyhow::Error::new(elapsed).context("reading the roster");
    assert_eq!(classify(&e).code, Code::Timeout);
}

/// A typed non-socket cause naming the daemon is not unreachable; text matching is only the
/// fallback for untyped errors.
#[test]
fn a_typed_permission_error_naming_the_daemon_stays_untyped_text() {
    let e =
        anyhow::Error::new(Io::new(ErrorKind::PermissionDenied, "denied")).context("daemon socket");
    assert_eq!(typed_kind(&e), None);
    let legacy = anyhow::anyhow!("the daemon went away");
    assert_eq!(classify(&legacy).detail, "daemon_unreachable");
}
