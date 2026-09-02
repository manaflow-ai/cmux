import Foundation

/// Classifies Sentry-bound error text so expected, non-actionable transport
/// disconnects can be dropped before capture or send.
public struct SentryNoiseFilter: Sendable {
    public init() {}

    /// Returns `true` when a structured CLI protocol code is the lifecycle
    /// `unavailable` code; callers must also inspect its message/context before
    /// suppressing telemetry because the code is reused by actionable failures.
    ///
    /// The check is intentionally narrow: only the protocol's `unavailable`
    /// code is lifecycle noise. Other codes, including `not_found` and
    /// `internal_error`, remain eligible for Sentry reporting.
    public func isExpectedCLIErrorCode(_ code: String?) -> Bool {
        normalizedCLIErrorCode(code) == "unavailable"
    }

    /// Returns `true` when an `unavailable` code carries known app-lifecycle
    /// text rather than an actionable service failure.
    public func isExpectedCLIAppLifecycleError(code: String?, message: String) -> Bool {
        isExpectedCLIErrorCode(code) && isExpectedCLIProtocolLifecycleMessage(message)
    }

    /// Returns `true` for protocol outcomes that reflect routine caller or
    /// resource state rather than a server-side failure worth sending to Sentry.
    ///
    /// The list is deliberately conservative. Unknown codes remain reportable
    /// so a newly introduced server failure cannot disappear silently.
    public func isExpectedCLIProtocolOutcomeCode(_ code: String?) -> Bool {
        guard let normalized = normalizedCLIErrorCode(code) else {
            return false
        }
        switch normalized {
        case "already_exists",
             "browser_disabled",
             "invalid_params",
             "invalid_request",
             "method_not_found",
             "not_found",
             "not_supported",
             "protected",
             "unrecognized_method",
             "unsupported",
             "validation_failed":
            return true
        default:
            return false
        }
    }

    /// Returns `true` for the legacy app-lifecycle text emitted by agent hooks.
    ///
    /// Agent-hook failures intentionally report a privacy-reduced wrapper, so
    /// callers may pass the original error here when its structured code is
    /// unavailable. The caller must still restrict this check to an agent-hook
    /// stage; this method does not classify arbitrary Sentry messages.
    public func isExpectedLegacyCLIAppLifecycleMessage(_ text: String) -> Bool {
        isExpectedCLIProtocolLifecycleMessage(text)
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
        if socketPathMissing { return true }
        if let normalizedCode = normalizedCLIErrorCode(cliErrorCode) {
            return normalizedCode == "unavailable"
                && isExpectedCLIProtocolLifecycleMessage(message)
        }
        return isExpectedCLIProtocolLifecycleMessage(message) ||
            isExpectedCLISocketTransportMessage(message) ||
            isExpectedCLISocketLifecycleRaceMessage(message) ||
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

    /// Matches the CLI's bare "Not connected" failure: the app's socket went
    /// away between a successful connect and the request write, typically the
    /// app quitting or restarting mid-hook. The same lifecycle race as the
    /// muted broken-pipe/ENOENT cases, but its rendered message carries no
    /// socket wording, so it is matched exactly and, via the guard above, only
    /// inside a proven CLI socket transport context.
    private func isExpectedCLISocketLifecycleRaceMessage(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "not connected"
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
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Only lifecycle-specific text is expected noise. The protocol also
        // uses `unavailable` for actionable service failures, so the code alone
        // is never sufficient to suppress an event.
        return normalized.hasPrefix("tabmanager not available") ||
            normalized.hasPrefix("error: tabmanager not available") ||
            normalized.hasPrefix("unavailable: tabmanager not available") ||
            normalized.hasPrefix("clierror: tabmanager not available") ||
            normalized.hasPrefix("clierror: unavailable: tabmanager not available") ||
            normalized.hasPrefix("appdelegate not available") ||
            normalized.hasPrefix("error: appdelegate not available") ||
            normalized.hasPrefix("unavailable: appdelegate not available") ||
            normalized.hasPrefix("control context unavailable") ||
            normalized.hasPrefix("unavailable: control context unavailable") ||
            normalized.hasPrefix("workspace context is unavailable") ||
            normalized.hasPrefix("unavailable: workspace context is unavailable") ||
            normalized == "the app is still starting" ||
            normalized == "cmux is still opening"
    }

    private func containsErrno(_ code: Int, in text: String) -> Bool {
        let escapedCode = NSRegularExpression.escapedPattern(for: String(code))
        let pattern = #"(?<![0-9])errno[[:space:]:=]*\#(escapedCode)(?![0-9])"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
