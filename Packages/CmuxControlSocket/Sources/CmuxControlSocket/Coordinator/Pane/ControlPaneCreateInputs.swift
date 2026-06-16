public import Foundation

/// The pre-parsed primitive inputs `pane.create` carries, as
/// ``ControlCommandCoordinator`` hands them to ``ControlPaneContext``.
///
/// The coordinator parses each value from the request params with its helpers
/// (mirroring the legacy `v2*` parsing exactly); the seam runs the app-coupled
/// work (direction parsing, panel-type resolution, browser availability, the
/// split creation). No app types cross the seam.
public struct ControlPaneCreateInputs: Sendable, Equatable {
    /// The trimmed `direction` string, if present (legacy `v2String`). The seam
    /// parses it to a split direction and rejects a missing or unknown value.
    public let directionRaw: String?
    /// The trimmed `type` string, if present (legacy `v2String`). The seam
    /// resolves it to a panel type, defaulting to terminal when absent/unknown.
    public let typeRaw: String?
    /// The raw `url` string, if present (legacy `v2String`), used for the URL
    /// and the browser-disabled error data.
    public let urlRaw: String?
    /// The trimmed-non-empty `working_directory`, if any (legacy
    /// `v2OptionalTrimmedRawString`).
    public let workingDirectory: String?
    /// The trimmed-non-empty `initial_command`, if any.
    public let initialCommand: String?
    /// The trimmed-non-empty `tmux_start_command`, if any.
    public let tmuxStartCommand: String?
    /// The startup environment map (legacy `v2TrimmedStringMap` over
    /// `startup_environment` / `initial_env`).
    public let startupEnvironment: [String: String]
    /// The requested source surface id (legacy `v2String("surface_id")` parsed
    /// as a UUID string), if any.
    public let requestedSourceSurfaceID: UUID?
    /// Whether the request asked to focus the new pane (legacy `v2Bool`,
    /// defaulting to false). The seam applies the socket focus-allowance gate.
    public let requestedFocus: Bool
    /// Whether an `initial_divider_position` param was present and non-null
    /// (legacy `v2HasNonNullParam`), so the seam knows to validate it.
    public let hasInitialDividerPosition: Bool
    /// The raw `initial_divider_position` value, if present (legacy `v2Double`,
    /// pre-clamp). The seam validates finiteness and clamps to `[0.1, 0.9]`.
    public let initialDividerPositionRaw: Double?
    /// The raw `placement` string, if present. The seam resolves it to the
    /// target container (main workspace vs. right-sidebar Dock), defaulting to
    /// the workspace when absent.
    public let placementRaw: String?

    /// Creates the pane-create inputs.
    ///
    /// - Parameters:
    ///   - directionRaw: The trimmed `direction` string, if present.
    ///   - typeRaw: The trimmed `type` string, if present.
    ///   - urlRaw: The raw `url` string, if present.
    ///   - workingDirectory: The trimmed-non-empty working directory, if any.
    ///   - initialCommand: The trimmed-non-empty initial command, if any.
    ///   - tmuxStartCommand: The trimmed-non-empty tmux start command, if any.
    ///   - startupEnvironment: The startup environment map.
    ///   - requestedSourceSurfaceID: The requested source surface id, if any.
    ///   - requestedFocus: Whether to focus the new pane.
    ///   - hasInitialDividerPosition: Whether a divider param was present.
    ///   - initialDividerPositionRaw: The raw divider value, if present.
    ///   - placementRaw: The raw `placement` string, if present.
    public init(
        directionRaw: String?,
        typeRaw: String?,
        urlRaw: String?,
        workingDirectory: String?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        startupEnvironment: [String: String],
        requestedSourceSurfaceID: UUID?,
        requestedFocus: Bool,
        hasInitialDividerPosition: Bool,
        initialDividerPositionRaw: Double?,
        placementRaw: String? = nil
    ) {
        self.directionRaw = directionRaw
        self.typeRaw = typeRaw
        self.urlRaw = urlRaw
        self.workingDirectory = workingDirectory
        self.initialCommand = initialCommand
        self.tmuxStartCommand = tmuxStartCommand
        self.startupEnvironment = startupEnvironment
        self.requestedSourceSurfaceID = requestedSourceSurfaceID
        self.requestedFocus = requestedFocus
        self.hasInitialDividerPosition = hasInitialDividerPosition
        self.initialDividerPositionRaw = initialDividerPositionRaw
        self.placementRaw = placementRaw
    }
}
