import Darwin
import Foundation

/// Decides whether a CLI socket `EPERM` is a proven agent sandbox denial
/// instead of an actionable Sentry error.
public struct CLISocketSentryPolicy: Sendable {
    /// Whether a socket-connect `EPERM` may be suppressed as an expected
    /// restricted-sandbox denial.
    public let allowsSandboxPolicyDenial: Bool

    private let hasTrustedPolicyDenialProvenance: Bool

    /// Creates a policy from the CLI process environment.
    ///
    /// - Parameter environment: The process environment. Callers must not add
    ///   `CODEX_SANDBOX`, `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, or
    ///   `CMUX_CLAUDE_PID` from command arguments or other untrusted input.
    public init(
        environment: [String: String],
        command: String = "",
        subcommand: String = ""
    ) {
        let rawSandbox = environment["CODEX_SANDBOX"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let restrictedValues: Set<String> = [
            "read-only",
            "seatbelt",
            "workspace-write"
        ]
        let hasRestrictedCodexSandbox = rawSandbox.map(restrictedValues.contains) ?? false
        allowsSandboxPolicyDenial = hasRestrictedCodexSandbox

        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSubcommand = subcommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isClaudeHookCommand = normalizedCommand == "claude-hook" ||
            (normalizedCommand == "hooks" && normalizedSubcommand == "claude")
        let hasClaudeHookIdentity = hasNonemptyValue(environment["CMUX_WORKSPACE_ID"]) &&
            hasNonemptyValue(environment["CMUX_SURFACE_ID"]) &&
            hasPositiveProcessID(environment["CMUX_CLAUDE_PID"])

        hasTrustedPolicyDenialProvenance = hasRestrictedCodexSandbox ||
            (isClaudeHookCommand && hasClaudeHookIdentity)
    }

    /// Suppresses only an owned Unix socket rejected with `EPERM` while the
    /// process has trusted restricted-agent provenance. Every missing or
    /// mismatched identity remains visible in Sentry.
    public func shouldSuppressPolicyDenial(_ context: CLISocketPolicyDenialContext) -> Bool {
        context.stage == "socket_connect" &&
            context.errnoCode == EPERM &&
            context.socketExists &&
            context.socketIsUnixDomainSocket &&
            context.socketOwnerUID == context.processUID &&
            context.processUID == context.effectiveUID &&
            hasTrustedPolicyDenialProvenance
    }

}

private func hasNonemptyValue(_ value: String?) -> Bool {
    !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
}

private func hasPositiveProcessID(_ value: String?) -> Bool {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          let processID = Int32(value) else {
        return false
    }
    return processID > 0
}
