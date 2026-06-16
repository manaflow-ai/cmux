import Foundation

/// Classifies Sentry-bound error text so expected, non-actionable transport
/// disconnects can be dropped before capture or send.
public struct SentryNoiseFilter: Sendable {
    public init() {}

    /// Returns `true` when a CLI socket transport stage failed because the peer
    /// was absent, refused the connection, or disappeared during a write.
    public func isExpectedCLISocketTransportFailure(
        stage: String,
        message: String,
        dataKeys: Set<String> = []
    ) -> Bool {
        guard isCLISocketTransportContext(stage: stage, dataKeys: dataKeys) else {
            return false
        }
        return isExpectedCLISocketTransportMessage(message)
    }

    /// Returns `true` for expected CLI socket connect/write error messages that
    /// are normal lifecycle races at fleet scale.
    public func isExpectedCLISocketTransportMessage(_ text: String) -> Bool {
        let t = text.lowercased()

        let isSocketWriteFailure =
            t.contains("failed to write to socket") ||
            t.contains("write to socket")
        if isSocketWriteFailure {
            return t.contains("broken pipe") ||
                t.contains("errno 32") ||       // EPIPE
                t.contains("connection reset") ||
                t.contains("errno 54") ||       // ECONNRESET
                t.contains("bad file descriptor") ||
                t.contains("errno 9") ||        // EBADF after peer/fd teardown
                t.contains("socket is not connected") ||
                t.contains("errno 57")          // ENOTCONN
        }

        let isSocketConnectFailure =
            t.contains("failed to connect to socket") ||
            t.contains("socket not found at")
        guard isSocketConnectFailure else {
            return false
        }

        return t.contains("socket not found at") ||
            t.contains("no such file or directory") ||
            t.contains("errno 2") ||            // ENOENT
            t.contains("connection refused") ||
            t.contains("errno 61")              // ECONNREFUSED
    }

    private func isCLISocketTransportContext(stage: String, dataKeys: Set<String>) -> Bool {
        stage == "socket_connect" ||
            stage.hasPrefix("socket_command") ||
            dataKeys.contains("socket_phase") ||
            dataKeys.contains("socket_operation")
    }
}
