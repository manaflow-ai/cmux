public import Foundation

/// The pre-parsed inputs for `surface.split`, lifted from the legacy
/// `v2SurfaceSplit` body's param parsing.
///
/// The coordinator parses the raw tokens; the app maps `directionRaw` →
/// `SplitDirection`, `typeRaw` → `PanelType`, and `urlRaw` → `URL` (so Bonsplit /
/// PanelType / URL-availability stay app-side). The coordinator pre-validates and
/// clamps the divider. The app resolves panel, provider, and renderer tokens
/// against its concrete surface types.
public struct ControlSurfaceSplitInputs: Sendable, Equatable {
    /// The raw `direction` token (validated non-nil/non-empty by the coordinator).
    public let directionRaw: String
    /// The raw `type` token, or `nil` (defaults to terminal).
    public let typeRaw: String?
    /// The raw agent-session provider token, or `nil` (defaults app-side).
    public let providerRaw: String?
    /// The raw agent-session renderer token, or `nil` (defaults app-side).
    public let rendererRaw: String?
    /// The raw agent-session model id, or `nil`.
    public let modelRaw: String?
    /// The raw OpenCode provider id for brokered models, or `nil`.
    public let openCodeProviderRaw: String?
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
    ///
    /// - Parameters:
    ///   - directionRaw: The raw split direction token.
    ///   - typeRaw: The raw surface type token, if present.
    ///   - providerRaw: The raw agent-session provider token, if present.
    ///   - rendererRaw: The raw agent-session renderer token, if present.
    ///   - modelRaw: The raw agent-session model id, if present.
    ///   - openCodeProviderRaw: The raw OpenCode provider id, if present.
    ///   - urlRaw: The raw browser URL string, if present.
    ///   - requestedSourceSurfaceID: The requested source surface id, if any.
    ///   - workingDirectory: The trimmed-non-empty working directory, if any.
    ///   - initialCommand: The trimmed-non-empty initial command, if any.
    ///   - tmuxStartCommand: The trimmed-non-empty tmux start command, if any.
    ///   - remotePTYSessionID: The trimmed-non-empty remote PTY session id, if any.
    ///   - startupEnvironment: The startup environment map.
    ///   - clientUnsupportedRemoteTmuxOptions: Options the caller cannot honor for routed remote tmux splits.
    ///   - requestedFocus: Whether to focus the new split.
    ///   - initialDividerPosition: The clamped initial divider position, if present.
    public init(
        directionRaw: String,
        typeRaw: String?,
        providerRaw: String?,
        rendererRaw: String?,
        modelRaw: String?,
        openCodeProviderRaw: String?,
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
        self.providerRaw = providerRaw
        self.rendererRaw = rendererRaw
        self.modelRaw = modelRaw
        self.openCodeProviderRaw = openCodeProviderRaw
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
