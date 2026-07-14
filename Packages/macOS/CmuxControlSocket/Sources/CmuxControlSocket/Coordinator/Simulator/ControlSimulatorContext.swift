public import Foundation

/// The simulator-domain seam ``ControlCommandCoordinator`` reaches live app
/// state through: opening a simulator pane for a device and closing one.
/// (`simulator.list` runs on the socket-worker lane app-side because it
/// blocks on `simctl`.)
@MainActor
public protocol ControlSimulatorContext: AnyObject {
    /// Opens a simulator pane for a device in the resolved workspace.
    ///
    /// - Parameters:
    ///   - routing: The request's routing selectors.
    ///   - workspaceID: The explicit target workspace, if given.
    ///   - deviceQuery: The device to display, as a name or UDID.
    ///   - requestedFocus: Whether the caller asked the new pane to take
    ///     focus (still gated by the socket focus policy app-side).
    /// - Returns: The resolution to reply with.
    func controlSimulatorOpen(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        deviceQuery: String,
        requestedFocus: Bool
    ) -> ControlSimulatorOpenResolution

    /// Closes a simulator pane in the resolved workspace.
    ///
    /// - Parameters:
    ///   - routing: The request's routing selectors.
    ///   - workspaceID: The explicit target workspace, if given.
    ///   - surfaceID: The explicit pane to close; when `nil`, the
    ///     workspace's only simulator pane is closed (ambiguity is an error).
    /// - Returns: The resolution to reply with.
    func controlSimulatorClose(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        surfaceID: UUID?
    ) -> ControlSimulatorCloseResolution
}

/// The outcome of `simulator.open`.
public enum ControlSimulatorOpenResolution: Sendable {
    /// No TabManager is available yet.
    case tabManagerUnavailable
    /// The `simulator.beta.enabled` flag is off.
    case featureDisabled
    /// The target workspace was not found.
    case notFound
    /// Pane creation failed.
    case openFailed
    /// The pane was created.
    case opened(windowID: UUID?, workspaceID: UUID, paneID: UUID?, surfaceID: UUID)
}

/// The outcome of `simulator.close`.
public enum ControlSimulatorCloseResolution: Sendable {
    /// No TabManager is available yet.
    case tabManagerUnavailable
    /// The `simulator.beta.enabled` flag is off.
    case featureDisabled
    /// The target workspace was not found.
    case notFound
    /// No matching simulator pane exists in the workspace.
    case surfaceNotFound
    /// Several simulator panes exist and no `surface_id` disambiguated.
    case ambiguous(count: Int)
    /// The pane was closed.
    case closed(workspaceID: UUID, surfaceID: UUID)
}
