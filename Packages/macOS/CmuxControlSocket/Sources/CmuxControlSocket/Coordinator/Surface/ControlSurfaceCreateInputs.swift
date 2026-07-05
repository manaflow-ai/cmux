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
    /// The raw `placement` string, if present. The seam resolves it to the
    /// target container (main workspace vs. right-sidebar Dock), defaulting to
    /// the workspace when absent.
    public let placementRaw: String?

    /// Creates surface-create inputs.
    public init(
        typeRaw: String?,
        providerRaw: String?,
        rendererRaw: String?,
        urlRaw: String?,
        workingDirectory: String?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        remotePTYSessionID: String?,
        startupEnvironment: [String: String],
        requestedPaneID: UUID?,
        requestedFocus: Bool,
        placementRaw: String? = nil
    ) {
        self.typeRaw = typeRaw
        self.providerRaw = providerRaw
        self.rendererRaw = rendererRaw
        self.urlRaw = urlRaw
        self.workingDirectory = workingDirectory
        self.initialCommand = initialCommand
        self.tmuxStartCommand = tmuxStartCommand
        self.remotePTYSessionID = remotePTYSessionID
        self.startupEnvironment = startupEnvironment
        self.requestedPaneID = requestedPaneID
        self.requestedFocus = requestedFocus
        self.placementRaw = placementRaw
    }
}
