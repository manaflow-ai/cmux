public import Foundation

/// The pre-parsed inputs for `surface.create`, lifted from the legacy
/// `v2SurfaceCreate` body's param parsing.
///
/// The coordinator parses the raw tokens; the app maps `typeRaw` → `PanelType`,
/// `urlRaw` → `URL`, and (for agent sessions) the raw provider/renderer tokens →
/// the app enums, returning the matching invalid resolution on a bad token. The
/// agent-session option parsing happens only when the type is `agent-session`,
/// exactly as the legacy body.
public struct ControlSurfaceCreateInputs: Sendable, Equatable {
    /// The raw `type` token, or `nil` (defaults to terminal).
    public let typeRaw: String?
    /// The raw `provider_id`/`provider` token, or `nil` (defaults to codex).
    public let providerRaw: String?
    /// The raw `renderer_kind`/`renderer` token, or `nil` (defaults to react).
    public let rendererRaw: String?
    /// The raw agent-session model id, or `nil`.
    public let modelRaw: String?
    /// The raw OpenCode provider id for brokered models, or `nil`.
    public let openCodeProviderRaw: String?
    /// The raw `url` string, or `nil`.
    public let urlRaw: String?
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
    /// The requested target `pane_id`, or `nil` for the focused pane.
    public let requestedPaneID: UUID?
    /// Whether the request asked to focus the new surface.
    public let requestedFocus: Bool

    /// Creates surface-create inputs.
    ///
    /// - Parameters:
    ///   - typeRaw: The raw surface type token, if present.
    ///   - providerRaw: The raw agent-session provider token, if present.
    ///   - rendererRaw: The raw agent-session renderer token, if present.
    ///   - modelRaw: The raw agent-session model id, if present.
    ///   - openCodeProviderRaw: The raw OpenCode provider id, if present.
    ///   - urlRaw: The raw browser URL string, if present.
    ///   - workingDirectory: The trimmed-non-empty working directory, if any.
    ///   - initialCommand: The trimmed-non-empty initial command, if any.
    ///   - tmuxStartCommand: The trimmed-non-empty tmux start command, if any.
    ///   - remotePTYSessionID: The trimmed-non-empty remote PTY session id, if any.
    ///   - startupEnvironment: The startup environment map.
    ///   - requestedPaneID: The requested target pane id, if any.
    ///   - requestedFocus: Whether to focus the new surface.
    public init(
        typeRaw: String?,
        providerRaw: String?,
        rendererRaw: String?,
        modelRaw: String?,
        openCodeProviderRaw: String?,
        urlRaw: String?,
        workingDirectory: String?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        remotePTYSessionID: String?,
        startupEnvironment: [String: String],
        requestedPaneID: UUID?,
        requestedFocus: Bool
    ) {
        self.typeRaw = typeRaw
        self.providerRaw = providerRaw
        self.rendererRaw = rendererRaw
        self.modelRaw = modelRaw
        self.openCodeProviderRaw = openCodeProviderRaw
        self.urlRaw = urlRaw
        self.workingDirectory = workingDirectory
        self.initialCommand = initialCommand
        self.tmuxStartCommand = tmuxStartCommand
        self.remotePTYSessionID = remotePTYSessionID
        self.startupEnvironment = startupEnvironment
        self.requestedPaneID = requestedPaneID
        self.requestedFocus = requestedFocus
    }
}
