import Foundation

/// Classifies Sentry-bound error text so expected, non-actionable transport
/// disconnects can be dropped before capture or send.
public struct SentryNoiseFilter: Sendable {
    public init() {}

    /// Returns `true` when a structured CLI protocol code denotes an expected
    /// app-lifecycle response rather than an actionable failure.
    ///
    /// The check is intentionally narrow: only the protocol's `unavailable`
    /// code is lifecycle noise. Other codes, including `not_found` and
    /// `internal_error`, remain eligible for Sentry reporting.
    public func isExpectedCLIErrorCode(_ code: String?) -> Bool {
        normalizedCLIErrorCode(code) == "unavailable"
    }

    /// Returns `true` for the legacy app-lifecycle text emitted by agent hooks.
    ///
    /// Agent-hook failures intentionally report a privacy-reduced wrapper, so
    /// callers may pass the original error here when its structured code is
    /// unavailable. The caller must still restrict this check to an agent-hook
    /// stage; this method does not classify arbitrary Sentry messages.
    public func isExpectedLegacyCLIAppLifecycleMessage(_ text: String) -> Bool {
        text.lowercased().contains("tabmanager not available")
    }

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
    ///   - cliErrorCode: The structured v2 code carried by a CLI error.
    ///     `unavailable` is an expected app-lifecycle response when it is
    ///     returned through a CLI socket command.
    ///   - socketPathMissing: Whether the typed CLI error identified a missing
    ///     socket path.
    /// - Returns: `true` when the failure is safe to omit from Sentry.
    public func isExpectedCLISocketTransportFailure(
        stage: String,
        message: String,
        dataKeys: Set<String> = [],
        allowSandboxPolicyDenial: Bool = false,
        cliErrorCode: String? = nil,
        socketPathMissing: Bool = false
    ) -> Bool {
        guard isCLISocketTransportContext(stage: stage, dataKeys: dataKeys) else {
            return false
        }
        // A protocol code is authoritative. Do not let a localized/legacy
        // message override an explicitly actionable code.
        if let normalizedCode = normalizedCLIErrorCode(cliErrorCode) {
            return normalizedCode == "unavailable" || socketPathMissing
        }
        if socketPathMissing { return true }
        return isExpectedCLIProtocolLifecycleMessage(message) ||
            isExpectedCLISocketTransportMessage(message) ||
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

    private func normalizedCLIErrorCode(_ code: String?) -> String? {
        guard let normalized = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private func isExpectedCLIProtocolLifecycleMessage(_ text: String) -> Bool {
        let normalized = text.lowercased()
        // V2 formats protocol failures as `unavailable: <message>`. Keep this
        // legacy fallback behind ``isExpectedCLISocketTransportFailure`` so a
        // free-form Sentry message cannot be mistaken for a socket response.
        return normalized.contains("unavailable:") ||
            normalized.contains("tabmanager not available")
    }

    private func containsErrno(_ code: Int, in text: String) -> Bool {
        let escapedCode = NSRegularExpression.escapedPattern(for: String(code))
        let pattern = #"(?<![0-9])errno[[:space:]:=]*\#(escapedCode)(?![0-9])"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
