import Foundation

public struct CLISocketSentryPolicy: Sendable {
    public let allowsSandboxPolicyDenial: Bool

    public init(environment: [String: String]) {
        guard let rawSandbox = environment["CODEX_SANDBOX"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawSandbox.isEmpty
        else {
            allowsSandboxPolicyDenial = false
            return
        }

        let unrestrictedValues: Set<String> = [
            "danger-full-access",
            "disabled",
            "none",
            "off",
            "unrestricted"
        ]
        allowsSandboxPolicyDenial = !unrestrictedValues.contains(rawSandbox)
    }
}
