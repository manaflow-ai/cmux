import Foundation

/// Classifies Sentry-bound error text so expected, non-actionable transport
/// disconnects can be dropped before capture or send.
public struct SentryNoiseFilter: Sendable {
    public init() {}

    /// Returns `true` for an expected CLI socket lifecycle failure.
    ///
    /// - Parameters:
    ///   - stage: The structured telemetry stage for the failed operation.
    ///   - message: The rendered transport error.
    ///   - dataKeys: Structured context keys that can prove socket ownership.
    ///   - allowSandboxPolicyDenial: Whether a socket-connect `EPERM` has
    ///     trusted restricted-sandbox provenance. Pass
    ///     ``CLISocketSentryPolicy/allowsSandboxPolicyDenial`` rather than
    ///     inferring this from the error text.
    /// - Returns: `true` when the failure is safe to omit from Sentry.
    public func isExpectedCLISocketTransportFailure(
        stage: String,
        message: String,
        dataKeys: Set<String> = [],
        allowSandboxPolicyDenial: Bool = false
    ) -> Bool {
        guard isCLISocketTransportContext(stage: stage, dataKeys: dataKeys) else {
            return false
        }
        return isExpectedCLISocketTransportMessage(message) ||
            (allowSandboxPolicyDenial && isSocketConnectPolicyDenial(message))
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
                containsErrno(32, in: t) ||      // EPIPE
                t.contains("connection reset") ||
                containsErrno(54, in: t) ||      // ECONNRESET
                t.contains("bad file descriptor") ||
                containsErrno(9, in: t) ||       // EBADF after peer/fd teardown
                t.contains("socket is not connected") ||
                containsErrno(57, in: t)         // ENOTCONN
        }

        let isSocketConnectFailure =
            t.contains("failed to connect to socket") ||
            t.contains("socket not found at")
        guard isSocketConnectFailure else {
            return false
        }

        return t.contains("socket not found at") ||
            t.contains("no such file or directory") ||
            containsErrno(2, in: t) ||           // ENOENT
            t.contains("connection refused") ||
            containsErrno(61, in: t)              // ECONNREFUSED
    }

    private func isSocketConnectPolicyDenial(_ text: String) -> Bool {
        let t = text.lowercased()
        let isSocketConnectFailure =
            t.contains("failed to connect to socket") ||
            t.contains("socket not found at")
        return isSocketConnectFailure &&
            (t.contains("operation not permitted") || containsErrno(1, in: t))
    }

    private func isCLISocketTransportContext(stage: String, dataKeys: Set<String>) -> Bool {
        stage == "socket_connect" ||
            stage.hasPrefix("socket_command") ||
            dataKeys.contains("socket_phase") ||
            dataKeys.contains("socket_operation")
    }

    private func containsErrno(_ code: Int, in text: String) -> Bool {
        let escapedCode = NSRegularExpression.escapedPattern(for: String(code))
        let pattern = #"(?<![0-9])errno[[:space:]:=]*\#(escapedCode)(?![0-9])"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
