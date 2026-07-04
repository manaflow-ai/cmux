public import Foundation

/// A read-only snapshot of one surface row for the `surface.list` payload, as the
/// app target exposes it to ``ControlCommandCoordinator``.
///
/// Mirrors the legacy per-surface dictionary the `v2SurfaceList` body built, with
/// additive recoverable resume history for terminal surfaces. The coordinator
/// mints the surface and pane refs itself and writes the optional fields with
/// `null` defaults exactly as the legacy `v2OrNull` writes did. The
/// browser/terminal-only extras are carried as optionals: they are emitted only
/// when present, matching the legacy `if let` conditional key writes.
public struct ControlSurfaceSummary: Sendable, Equatable {
    /// The surface's panel identifier.
    public let surfaceID: UUID
    /// The panel type's raw value.
    public let typeRawValue: String
    /// The resolved display title.
    public let title: String
    /// Whether this surface is the workspace's focused surface.
    public let isFocused: Bool
    /// The enclosing pane's identifier, if it resolved.
    public let paneID: UUID?
    /// The surface's index within its pane, if it resolved.
    public let indexInPane: Int?
    /// Whether this surface is the selected tab in its pane, if it resolved.
    public let selectedInPane: Bool?
    /// For browser surfaces, whether developer tools are visible (else `nil`).
    public let developerToolsVisible: Bool?
    /// For terminal surfaces, the requested working directory (trimmed
    /// non-empty), else `nil`. Present only for terminal surfaces.
    public let requestedWorkingDirectory: String?
    /// For terminal surfaces, the initial command (trimmed non-empty), else
    /// `nil`. Present only for terminal surfaces.
    public let initialCommand: String?
    /// For terminal surfaces, the tmux start command (trimmed non-empty), else
    /// `nil`. Present only for terminal surfaces.
    public let tmuxStartCommand: String?
    /// Whether this surface is a terminal surface (drives the terminal-only key
    /// emission, including the always-present `resume_binding` key).
    public let isTerminal: Bool
    /// For terminal surfaces, the resume binding, else `nil`. Emitted as the
    /// `resume_binding` value (a `null` binding still emits the key).
    public let resumeBinding: ControlSurfaceResumeBinding?
    /// For terminal surfaces, the newest-first recoverable resume bindings.
    public let resumeBindingHistory: [ControlSurfaceResumeBinding]

    /// Creates a surface summary.
    ///
    /// - Parameters:
    ///   - surfaceID: The surface's panel identifier.
    ///   - typeRawValue: The panel type's raw value.
    ///   - title: The resolved display title.
    ///   - isFocused: Whether this surface is focused.
    ///   - paneID: The enclosing pane's identifier, if resolved.
    ///   - indexInPane: The surface's index within its pane, if resolved.
    ///   - selectedInPane: Whether this surface is selected in its pane.
    ///   - developerToolsVisible: For browsers, whether dev tools are visible.
    ///   - requestedWorkingDirectory: For terminals, the requested working dir.
    ///   - initialCommand: For terminals, the initial command.
    ///   - tmuxStartCommand: For terminals, the tmux start command.
    ///   - isTerminal: Whether this is a terminal surface.
    ///   - resumeBinding: For terminals, the resume binding.
    ///   - resumeBindingHistory: For terminals, recoverable resume bindings.
    public init(
        surfaceID: UUID,
        typeRawValue: String,
        title: String,
        isFocused: Bool,
        paneID: UUID?,
        indexInPane: Int?,
        selectedInPane: Bool?,
        developerToolsVisible: Bool?,
        requestedWorkingDirectory: String?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        isTerminal: Bool,
        resumeBinding: ControlSurfaceResumeBinding?,
        resumeBindingHistory: [ControlSurfaceResumeBinding] = []
    ) {
        self.surfaceID = surfaceID
        self.typeRawValue = typeRawValue
        self.title = title
        self.isFocused = isFocused
        self.paneID = paneID
        self.indexInPane = indexInPane
        self.selectedInPane = selectedInPane
        self.developerToolsVisible = developerToolsVisible
        self.requestedWorkingDirectory = requestedWorkingDirectory
        self.initialCommand = initialCommand
        self.tmuxStartCommand = tmuxStartCommand
        self.isTerminal = isTerminal
        self.resumeBinding = resumeBinding
        self.resumeBindingHistory = resumeBindingHistory
    }
}
