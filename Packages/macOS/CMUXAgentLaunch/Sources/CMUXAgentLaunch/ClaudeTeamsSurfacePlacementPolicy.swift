import Foundation

/// Provides the dependency-free Claude Teams surface-placement launch contract.
///
/// The executable and terminal packages adapt this policy to their settings,
/// socket, and filesystem APIs. Keeping the environment and alias rules here
/// makes the cross-process boundary testable without launching the app.
public struct ClaudeTeamsSurfacePlacementPolicy: Sendable {
    /// The two destinations supported by Claude Teams teammate launches.
    public enum Placement: String, CaseIterable, Sendable {
        /// Create a teammate in a sibling cmux workspace.
        case workspace
        /// Create a teammate as a surface in the caller's workspace and pane.
        case surface
    }

    /// The Claude marker that authorizes the tmux compatibility environment.
    public static let teamsMarkerEnvironmentKey = "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"

    /// The cmux executable marker carried by a Claude Teams launch.
    public static let cmuxExecutableEnvironmentKey = "CMUX_CLAUDE_TEAMS_CMUX_BIN"

    /// The environment key containing a synthetic tmux pane alias.
    public static let tmuxPaneEnvironmentKey = "TMUX_PANE"

    private static let placementEnvironmentKey = "CMUX_CLAUDE_TEAMS_SPAWN_PLACEMENT"
    private static let bundledCLIEnvironmentKey = "CMUX_BUNDLED_CLI_PATH"
    private static let forwardedEnvironmentKeys = [
        teamsMarkerEnvironmentKey,
        "CLAUDE_CODE_SANDBOXED",
        "CMUX_CLAUDE_TEAMS_SANDBOXED",
        placementEnvironmentKey,
        cmuxExecutableEnvironmentKey,
        "CMUX_CLAUDE_TEAMS_TMUX_SHIM",
        "CMUX_CLAUDE_TEAMS_RESPAWN_ENV_B64",
        "TMUX",
    ]

    /// Creates a Claude Teams placement policy.
    public init() {}

    /// Reports whether an environment carries an independent Claude Teams marker.
    ///
    /// A shim path alone is deliberately insufficient: it is a requested
    /// executable and must not authorize Claude-specific environment forwarding.
    ///
    /// - Parameter environment: Process environment to inspect.
    /// - Returns: `true` when the Claude marker or cmux executable marker is valid.
    public func isClaudeTeamsEnvironment(_ environment: [String: String]) -> Bool {
        Self.hasExplicitTeamsMarker(environment)
            || Self.safeEnvironmentValue(environment[Self.cmuxExecutableEnvironmentKey])
    }

    /// Reports whether the environment explicitly identifies a Claude Teams launch.
    ///
    /// Restore records use this stricter check because a cmux executable marker
    /// can also be present in a non-Claude managed terminal.
    ///
    /// - Parameter environment: Process environment to inspect.
    /// - Returns: `true` only when the Claude Teams marker is exactly `"1"`.
    public static func hasExplicitTeamsMarker(_ environment: [String: String]) -> Bool {
        environment[Self.teamsMarkerEnvironmentKey] == "1"
    }

    /// Resolves the effective teammate destination for an authorized launch.
    ///
    /// - Parameters:
    ///   - rawValue: Explicit placement from the launch environment, if present.
    ///   - fallback: Persisted setting used when the launch has no explicit value.
    ///   - environment: Process environment whose markers authorize the choice.
    /// - Returns: A placement, defaulting to `.workspace` outside Claude Teams.
    public func placement(
        rawValue: String?,
        fallback: Placement = .workspace,
        environment: [String: String]
    ) -> Placement {
        guard isClaudeTeamsEnvironment(environment) else { return .workspace }
        if let rawValue,
           let explicit = Placement(
                rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
           ) {
            return explicit
        }
        return fallback
    }

    /// Selects replay-safe Claude Teams control variables from a process environment.
    ///
    /// - Parameters:
    ///   - environment: Lead or restored teammate process environment.
    ///   - placementRawValue: Optional destination to write into the forwarded context.
    /// - Returns: Safe control variables, or an empty dictionary outside Claude Teams.
    public func controlEnvironment(
        from environment: [String: String],
        placementRawValue: String? = nil
    ) -> [String: String] {
        guard isClaudeTeamsEnvironment(environment) else { return [:] }
        var result: [String: String] = [:]
        for key in Self.forwardedEnvironmentKeys {
            guard let value = environment[key], Self.safeEnvironmentValue(value) else { continue }
            result[key] = value
        }
        let effectivePlacement = placement(
            rawValue: placementRawValue ?? environment[Self.placementEnvironmentKey],
            environment: environment
        )
        result[Self.placementEnvironmentKey] = effectivePlacement.rawValue
        return result
    }

    /// Builds a teammate surface's replay-safe startup environment.
    ///
    /// - Parameters:
    ///   - aliasToken: Synthetic tmux pane token assigned before surface creation.
    ///   - transportEnvironment: Already-decoded, replay-safe provider environment.
    ///   - processEnvironment: Lead process environment carrying control markers.
    ///   - bundledExecutablePath: Optional cmux executable fallback.
    /// - Returns: Startup values with surface placement and `TMUX_PANE` installed.
    public func startupEnvironment(
        aliasToken: String,
        transportEnvironment: [String: String],
        processEnvironment: [String: String],
        bundledExecutablePath: String? = nil
    ) -> [String: String] {
        var startup = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: transportEnvironment,
            kind: "claude"
        )
        if let path = transportEnvironment["PATH"], Self.safeEnvironmentValue(path) {
            startup["PATH"] = path
        }
        startup.merge(
            controlEnvironment(from: processEnvironment, placementRawValue: Placement.surface.rawValue)
        ) { _, incoming in incoming }
        startup[Self.placementEnvironmentKey] = Placement.surface.rawValue
        if Self.safeEnvironmentValue(aliasToken) {
            startup[Self.tmuxPaneEnvironmentKey] = aliasToken
        }
        if startup[Self.cmuxExecutableEnvironmentKey] == nil {
            let fallback = bundledExecutablePath ?? processEnvironment[Self.bundledCLIEnvironmentKey]
            if let fallback, Self.safeEnvironmentValue(fallback) {
                startup[Self.cmuxExecutableEnvironmentKey] = fallback
            }
        }
        return startup
    }

    /// Encodes a real surface UUID as a stable tmux-shaped pane token.
    ///
    /// - Parameter surfaceID: UUID string identifying the real surface.
    /// - Returns: A token suitable for `TMUX_PANE` and tmux target arguments.
    public static func surfaceAliasToken(surfaceID: String) -> String {
        "%cmux-surface-\(surfaceID)"
    }

    /// Decodes and validates a synthetic surface token.
    ///
    /// - Parameter rawAlias: Token with an optional tmux `%` sigil.
    /// - Returns: The embedded UUID string, or `nil` for a non-alias token.
    public static func surfaceID(fromAlias rawAlias: String?) -> String? {
        guard let rawAlias else { return nil }
        var token = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = token.first, first == "$" || first == "@" || first == "%" {
            token.removeFirst()
            token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefix = "cmux-surface-"
        guard token.lowercased().hasPrefix(prefix), token.count > prefix.count else { return nil }
        let surfaceID = String(token.dropFirst(prefix.count))
        return UUID(uuidString: surfaceID) == nil ? nil : surfaceID
    }

    private static func safeEnvironmentValue(_ value: String?) -> Bool {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }
}
