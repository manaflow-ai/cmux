import Foundation

/// Decides whether a CLI socket `EPERM` can be treated as an expected Codex
/// sandbox denial instead of an actionable Sentry error.
///
/// Only a `CODEX_SANDBOX` value read directly from the process environment is
/// trusted as provenance. Known restricted values opt in. Missing, unknown, and
/// unrestricted values keep the error visible.
public struct CLISocketSentryPolicy: Sendable {
    /// Whether a socket-connect `EPERM` may be suppressed as an expected
    /// restricted-sandbox denial.
    public let allowsSandboxPolicyDenial: Bool

    /// Creates a policy from the CLI process environment.
    ///
    /// - Parameter environment: The process environment. Callers must not add
    ///   `CODEX_SANDBOX` from command arguments or other untrusted input.
    public init(environment: [String: String]) {
        guard let rawSandbox = environment["CODEX_SANDBOX"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawSandbox.isEmpty
        else {
            allowsSandboxPolicyDenial = false
            return
        }

        let restrictedValues: Set<String> = [
            "read-only",
            "seatbelt",
            "workspace-write"
        ]
        allowsSandboxPolicyDenial = restrictedValues.contains(rawSandbox)
    }
}
