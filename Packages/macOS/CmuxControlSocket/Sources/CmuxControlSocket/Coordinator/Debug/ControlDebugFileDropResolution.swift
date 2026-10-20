#if DEBUG
public import Foundation

/// The outcome of `debug.terminal.simulate_file_drop`, preserving the legacy
/// body's error ordering: panel resolution first, then (text-destination only)
/// the payload-kind check and workspace lookup, then the drop attempt.
public enum ControlDebugFileDropResolution: Sendable, Equatable {
    /// The terminal surface could not be resolved (legacy `not_found` /
    /// "Terminal surface not found").
    case panelNotFound
    /// An image-data payload was requested on the text-destination route
    /// (legacy `invalid_params` / "Image data payload requires terminal
    /// route").
    case imageDataRequiresTerminalRoute
    /// The panel's workspace no longer exists (legacy `not_found` /
    /// "Workspace not found"). Carries the workspace id for the error data.
    case workspaceNotFound(workspaceID: UUID)
    /// The terminal-route drop ran; `handled` is the view's result.
    case terminalDrop(handled: Bool)
    /// The text-destination drop ran; `handled` is the controller's result.
    case textDestinationDrop(handled: Bool)
}
#endif
