public import Foundation

/// The pre-parsed inputs for `surface.respawn`, lifted from the legacy
/// `v2SurfaceRespawn` body's param parsing.
///
/// The coordinator parses these and detects the invalid-focus error itself (so the
/// localized message resolves through ``ControlSurfaceRespawnStrings``). The
/// `requestedSurfaceID` carries the explicit-`surface_id` branch: when
/// `hasSurfaceIDParam` is `true` but the id did not parse, the app returns the
/// not-found resolution (matching the legacy body).
public struct ControlSurfaceRespawnInputs: Sendable, Equatable {
    /// The resume/respawn command (with the legacy
    /// `exec ${SHELL:-/bin/zsh} -l` default already applied).
    public let command: String
    /// The tmux start command (defaults to `command`).
    public let tmuxStartCommand: String
    /// The trimmed-non-empty working directory, or `nil`.
    public let workingDirectory: String?
    /// Whether a non-null `surface_id` param was present (drives the explicit vs
    /// focused-surface branch).
    public let hasSurfaceIDParam: Bool
    /// The resolved explicit `surface_id`, if it parsed.
    public let requestedSurfaceID: UUID?
    /// Whether a non-null `focus` param was present (when absent the app passes
    /// `nil` focus to the respawn call, matching the legacy body).
    public let hasFocusParam: Bool
    /// The parsed `focus` value (used only when `hasFocusParam`); the app applies
    /// the socket focus-allowance gate.
    public let requestedFocus: Bool
    /// Explicit environment values merged over inherited values for local respawns.
    /// Remote providers retain their remote session environment. Managed cmux
    /// identity variables stay protected; provider values include `PATH` and
    /// `OPENCODE_PORT` supplied by either respawn CLI entrypoint.
    public let startupEnvironment: [String: String]

    /// Creates respawn inputs.
    ///
    /// - Parameter startupEnvironment: Explicit local replacement environment,
    ///   defaulting to no caller overrides.
    public init(
        command: String,
        tmuxStartCommand: String,
        workingDirectory: String?,
        hasSurfaceIDParam: Bool,
        requestedSurfaceID: UUID?,
        hasFocusParam: Bool,
        requestedFocus: Bool,
        startupEnvironment: [String: String] = [:]
    ) {
        self.command = command
        self.tmuxStartCommand = tmuxStartCommand
        self.workingDirectory = workingDirectory
        self.hasSurfaceIDParam = hasSurfaceIDParam
        self.requestedSurfaceID = requestedSurfaceID
        self.hasFocusParam = hasFocusParam
        self.requestedFocus = requestedFocus
        self.startupEnvironment = startupEnvironment
    }
}
