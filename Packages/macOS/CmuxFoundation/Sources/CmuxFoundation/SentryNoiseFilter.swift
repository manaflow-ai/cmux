import Darwin
import Foundation

/// Classifies Sentry-bound transport failures so expected, non-actionable
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
    ///     ``CLISocketSentryPolicy/shouldSuppressPolicyDenial(_:)`` rather
    ///     than inferring this from the error text.
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

    /// Uses typed connection fields when available so user-visible error text
    /// can stay sanitized without changing Sentry suppression semantics.
    public func isExpectedCLISocketTransportFailure(
        stage: String,
        error: any Error,
        dataKeys: Set<String> = [],
        allowSandboxPolicyDenial: Bool = false
    ) -> Bool {
        if let connectError = error as? CLISocketConnectError {
            guard isCLISocketTransportContext(stage: stage, dataKeys: dataKeys) else {
                return false
            }
            switch connectError.errnoCode {
            case ENOENT, ECONNREFUSED:
                return true
            case EPERM:
                return allowSandboxPolicyDenial
            default:
                return false
            }
        }

        return isExpectedCLISocketTransportFailure(
            stage: stage,
            message: String(describing: error),
            dataKeys: dataKeys,
            allowSandboxPolicyDenial: allowSandboxPolicyDenial
        )
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
