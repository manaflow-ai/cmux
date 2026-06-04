/// The recovery class of an `accept(2)` failure on the control-socket listener.
///
/// The raw values are stable identifiers recorded in telemetry breadcrumbs; do
/// not rename them.
public enum SocketAcceptErrorClassification: String, Equatable, Sendable {
    /// Transient per-connection errors (`EINTR`, `ECONNABORTED`, `EAGAIN`,
    /// `EWOULDBLOCK`); retry the accept immediately.
    case immediateRetry = "immediate_retry"
    /// Resource exhaustion (`EMFILE`, `ENFILE`, `ENOBUFS`, `ENOMEM`); back off
    /// before resuming.
    case resourcePressure = "resource_pressure"
    /// The listener descriptor itself is broken (`EBADF`, `EINVAL`, `ENOTSOCK`);
    /// the listener must be torn down and rearmed.
    case fatal = "fatal"
    /// Anything else; back off and retry.
    case retryWithBackoff = "retry_with_backoff"
}
