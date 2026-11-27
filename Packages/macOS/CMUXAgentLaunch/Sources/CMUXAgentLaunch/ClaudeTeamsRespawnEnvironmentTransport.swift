import Foundation

/// Carries replay-safe launcher environment values into Claude Teams teammate respawns.
///
/// Teammate panes are created by the cmux app process rather than the `cmux
/// claude-teams` launcher, so they cannot inherit the launcher's environment
/// directly. This transport preserves executable discovery through `PATH` and
/// delegates every other value to ``AgentLaunchEnvironmentPolicy`` so secrets
/// and process identity do not cross the respawn boundary.
public struct ClaudeTeamsRespawnEnvironmentTransport: Sendable {
    /// The process-environment key used to carry the encoded launch snapshot.
    public static let environmentKey = "CMUX_CLAUDE_TEAMS_RESPAWN_ENV_B64"

    private let environmentPolicy: AgentLaunchEnvironmentPolicy

    /// Creates a Claude Teams respawn environment transport.
    ///
    /// - Parameter environmentPolicy: The policy that selects replay-safe
    ///   environment values. The shared agent-launch policy is used by default.
    public init(
        environmentPolicy: AgentLaunchEnvironmentPolicy = AgentLaunchEnvironmentPolicy()
    ) {
        self.environmentPolicy = environmentPolicy
    }

    /// Encodes a launcher's replay-safe environment as a base64 JSON value.
    ///
    /// - Parameter launcherEnvironment: The final environment configured for the
    ///   Claude Teams lead process.
    /// - Returns: The encoded transport value, or `nil` if encoding fails.
    public func encodedValue(from launcherEnvironment: [String: String]) -> String? {
        let selected = selectedEnvironment(from: launcherEnvironment)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(selected) else { return nil }
        return data.base64EncodedString()
    }

    /// Decodes and revalidates a launch-scoped environment transport value.
    ///
    /// Invalid data fails closed. Reapplying the allowlist during decoding means
    /// a forged or modified transport value cannot promote credentials or process
    /// identity into a teammate pane.
    ///
    /// - Parameter encodedValue: The base64 JSON value read from
    ///   ``environmentKey``.
    /// - Returns: Replay-safe environment values for the teammate process.
    public func decodedEnvironment(from encodedValue: String?) -> [String: String] {
        guard let encodedValue,
              let data = Data(base64Encoded: encodedValue),
              let transported = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return selectedEnvironment(from: transported)
    }

    private func selectedEnvironment(from environment: [String: String]) -> [String: String] {
        var selected = environmentPolicy.selectedEnvironment(from: environment, kind: "claude")
        if let path = environment["PATH"] {
            selected["PATH"] = path
        }
        return selected
    }
}
