import Foundation

/// Computes per-agent environment overrides for cmux AI Gateway routing.
///
/// The policy is intentionally pure: callers own settings reads, secret reads,
/// and base-URL resolution, then pass those values in here.
public enum CoderouterEnvironmentPolicy {
    /// Returns environment variables that route `kind` through coderouter.
    ///
    /// Phase 2 supports Claude Code only. Disabled settings, empty secrets,
    /// empty gateway URLs, and unsupported kinds all return an empty dictionary.
    ///
    /// - Parameters:
    ///   - kind: The agent kind string, such as `"claude"`.
    ///   - enabled: Whether the user enabled coderouter routing.
    ///   - secret: The stored `crk_` gateway key.
    ///   - gatewayBaseURL: The gateway origin, without the family path suffix.
    /// - Returns: Environment overrides for the spawned agent process.
    public static func environment(
        kind: String,
        enabled: Bool,
        secret: String?,
        gatewayBaseURL: String
    ) -> [String: String] {
        guard enabled else { return [:] }
        guard kind == "claude" else { return [:] }
        guard let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else {
            return [:]
        }
        let baseURL = gatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else { return [:] }
        return [
            "ANTHROPIC_BASE_URL": baseURL.trimmingTrailingSlashes() + "/anthropic",
            "ANTHROPIC_AUTH_TOKEN": secret,
        ]
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var value = self
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
