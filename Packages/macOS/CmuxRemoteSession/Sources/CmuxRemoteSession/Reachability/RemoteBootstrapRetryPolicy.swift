import Foundation

/// Bounds automatic retries when the remote daemon bootstrap keeps failing.
///
/// Reachability answers whether SSH can reach the host; this policy answers
/// whether repeating the same bootstrap operation is still useful. Keeping
/// those decisions separate prevents a reachable host with a corrupt install
/// from consuming an unbounded reconnect loop.
struct RemoteBootstrapRetryPolicy: Sendable {
    static let stableFailureClassKey = "cmux.remote.bootstrap.failureClass"
    /// The decision after one bootstrap failure.
    enum Decision: Equatable, Sendable {
        /// Schedule another centrally-owned reconnect attempt.
        case retry
        /// Park the connection until the user explicitly reconnects.
        case suspend
    }

    /// The counters and decision produced for one failure.
    struct Evaluation: Equatable, Sendable {
        let fingerprint: String
        let consecutiveFailures: Int
        let totalFailures: Int
        let decision: Decision
    }

    /// Number of identical failures tolerated before parking the workspace.
    let maxConsecutiveFailures = 3
    /// Total bootstrap failures tolerated during one automatic reconnect run.
    let maxTotalFailures = 8

    /// Evaluates one failure against the previous retry counters.
    func evaluate(
        fingerprint: String,
        previousFingerprint: String?,
        previousConsecutiveFailures: Int,
        previousTotalFailures: Int
    ) -> Evaluation {
        let normalizedFingerprint = fingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let consecutiveFailures = previousFingerprint == normalizedFingerprint
            ? max(0, previousConsecutiveFailures) + 1
            : 1
        let totalFailures = max(0, previousTotalFailures) + 1
        let shouldSuspend = normalizedFingerprint.contains(":blocked") ||
            consecutiveFailures >= maxConsecutiveFailures ||
            totalFailures >= maxTotalFailures
        return Evaluation(
            fingerprint: normalizedFingerprint,
            consecutiveFailures: consecutiveFailures,
            totalFailures: totalFailures,
            decision: shouldSuspend ? .suspend : .retry
        )
    }

    /// Produces a stable failure class for retry accounting.
    ///
    /// Dynamic stderr (paths, byte counts, and elapsed times) is deliberately
    /// excluded. A truncated payload must remain the same failure class across
    /// attempts even when each temporary path or diagnostic count changes.
    static func fingerprint(for error: any Error) -> String {
        let annotatedError = error as NSError
        // Bootstrap diagnostics are intentionally appended after the real
        // failure.  Retry accounting must classify that underlying failure,
        // never a changing log tail/path/byte count.
        let nsError = (annotatedError.userInfo[NSUnderlyingErrorKey] as? NSError)
            ?? annotatedError
        let domain = nsError.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = nsError.code
        let className = (nsError.userInfo[stableFailureClassKey] as? String)
            ?? failureClass(for: nsError.localizedDescription)
        return "\(domain):\(code):\(className)"
    }

    private static func failureClass(for rawMessage: String) -> String {
        let message = rawMessage.lowercased()
        if message.contains("permission denied") ||
            message.contains("authentication") ||
            message.contains("host key") ||
            message.contains("access denied") {
            return "blocked"
        } else if message.contains("verification") || message.contains("checksum") || message.contains("hash") {
            return "integrity"
        } else if message.contains("hello") || message.contains("json") {
            return "hello"
        } else if message.contains("upload") || message.contains("transfer") {
            return "transfer"
        } else if message.contains("directory") || message.contains("install") {
            return "install"
        }
        return "bootstrap"
    }
}
