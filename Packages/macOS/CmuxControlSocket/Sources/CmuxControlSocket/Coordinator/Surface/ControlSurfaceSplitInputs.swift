public import Foundation

/// The pre-parsed inputs for `surface.split`, lifted from the legacy
/// `v2SurfaceSplit` body's param parsing.
///
/// The coordinator parses the raw tokens; the app maps `directionRaw` →
/// `SplitDirection`, `typeRaw` → `PanelType`, and `urlRaw` → `URL` (so Bonsplit /
/// PanelType / URL-availability stay app-side). The coordinator pre-validates and
/// clamps the divider, and pre-validates the agent-session rejection only as far as
/// the type token; the app rejects `agent-session` against its real `PanelType`.
public struct ControlSurfaceSplitInputs: Sendable, Equatable {
    /// The raw `direction` token (validated non-nil/non-empty by the coordinator).
    public let directionRaw: String
    /// The raw `type` token, or `nil` (defaults to terminal).
    public let typeRaw: String?
    /// The raw `url` string, or `nil`.
    public let urlRaw: String?
    /// The requested source `surface_id`, or `nil` to split the focused surface.
    public let requestedSourceSurfaceID: UUID?
    /// The trimmed-non-empty `working_directory`, or `nil`.
    public let workingDirectory: String?
    /// The trimmed-non-empty `initial_command`, or `nil`.
    public let initialCommand: String?
    /// The trimmed-non-empty `tmux_start_command`, or `nil`.
    public let tmuxStartCommand: String?
    /// The trimmed-non-empty `remote_pty_session_id`, or `nil`.
    public let remotePTYSessionID: String?
    /// The startup environment (`startup_environment`/`initial_env`), `[:]` if none.
    public let startupEnvironment: [String: String]
    /// Options the caller already knows a routed remote tmux split cannot honor.
    public let clientUnsupportedRemoteTmuxOptions: [String]
    /// Whether the request asked to focus the new split.
    public let requestedFocus: Bool
    /// The clamped `[0.1, 0.9]` initial divider position, or `nil`.
    public let initialDividerPosition: Double?

    /// Creates surface-split inputs.
    public init(
        directionRaw: String,
        typeRaw: String?,
        urlRaw: String?,
        requestedSourceSurfaceID: UUID?,
        workingDirectory: String?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        remotePTYSessionID: String?,
        startupEnvironment: [String: String],
        clientUnsupportedRemoteTmuxOptions: [String],
        requestedFocus: Bool,
        initialDividerPosition: Double?
    ) {
        self.directionRaw = directionRaw
        self.typeRaw = typeRaw
        self.urlRaw = urlRaw
        self.requestedSourceSurfaceID = requestedSourceSurfaceID
        self.workingDirectory = workingDirectory
        self.initialCommand = initialCommand
        self.tmuxStartCommand = tmuxStartCommand
        self.remotePTYSessionID = remotePTYSessionID
        self.startupEnvironment = startupEnvironment
        self.clientUnsupportedRemoteTmuxOptions = clientUnsupportedRemoteTmuxOptions
        self.requestedFocus = requestedFocus
        self.initialDividerPosition = initialDividerPosition
    }
}
