import Foundation

/// Classifies Sentry-bound error text so expected, non-actionable noise can be
/// dropped before it is captured or sent.
///
/// The CLI writes to Unix sockets and to stdout/stderr pipes whose peer (the
/// cmux app, a parent agent process, or a closed terminal) can disappear
/// mid-write. A write to a peer that has gone away is an expected disconnect,
/// not a bug, yet each one was being captured and flushed to Sentry. At fleet
/// scale that single signature accounted for the large majority of all error
/// events. This filter recognizes that signature so both the capture site and
/// `beforeSend` can discard it.
///
/// The match is intentionally narrow: only writes that failed with a
/// broken-pipe / connection-reset / bad-descriptor errno are treated as noise.
/// Every other write failure (timeouts, permission errors, missing socket, and
/// so on) still reports normally, so a genuinely new failure mode is not
/// silently hidden.
public enum SentryNoiseFilter {
    /// Returns `true` when `text` describes a write to a peer that has already
    /// gone away (a broken pipe, a reset connection, or a closed descriptor).
    ///
    /// `text` is typically `String(describing: error)` or a Sentry exception
    /// value such as `"Failed to write to socket (Broken pipe, errno 32)"`.
    public static func isExpectedPeerDisconnect(_ text: String) -> Bool {
        let t = text.lowercased()

        // Scope to write/send failures so an unrelated error that merely
        // mentions one of these tokens is not swallowed.
        let isWriteFailure =
            t.contains("write to socket")
            || t.contains("failed to write")
            || t.contains("broken pipe")
            || t.contains("sigpipe")
        guard isWriteFailure else { return false }

        return t.contains("broken pipe")
            || t.contains("errno 32")        // EPIPE
            || t.contains("sigpipe")
            || t.contains("connection reset")
            || t.contains("errno 54")        // ECONNRESET
            || t.contains("errno 9")         // EBADF (peer closed, fd reused)
    }
}
