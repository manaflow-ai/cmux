public import Foundation

/// A read-only snapshot of one pane in a workspace, as the app target exposes
/// it to ``ControlCommandCoordinator`` for the `pane.list` payload row.
///
/// Mirrors the legacy per-pane dictionary the `v2PaneList` body built from the
/// workspace's `bonsplitController`, without the package importing the app's
/// pane/Bonsplit types. The coordinator turns each summary into one row, minting
/// the pane/surface refs itself.
public struct ControlPaneSummary: Sendable, Equatable {
    /// The pane's stable identifier.
    public let paneID: UUID
    /// Whether this pane currently holds focus.
    public let isFocused: Bool
    /// The surfaces in this pane, in tab order.
    public let surfaceIDs: [UUID]
    /// The restart-stable identities for ``surfaceIDs``, in the same order.
    public let stableSurfaceIDs: [UUID]
    /// The selected surface in this pane, if any.
    public let selectedSurfaceID: UUID?
    /// The selected surface's restart-stable identity, if any.
    public let selectedStableSurfaceID: UUID?
    /// The pane's pixel frame, if the layout snapshot reported one.
    public let pixelFrame: ControlPanePixelFrame?
    /// The selected surface's terminal grid size, if it is live and reporting.
    public let gridSize: ControlPaneGridSize?
    /// The Dock container scope for Dock-hosted panes, else `nil`.
    public let dockScopeRawValue: String?

    /// Creates a pane summary.
    ///
    /// - Parameters:
    ///   - paneID: The pane's stable identifier.
    ///   - isFocused: Whether this pane holds focus.
    ///   - surfaceIDs: The surfaces in the pane, in tab order.
    ///   - stableSurfaceIDs: The restart-stable identities for the surfaces, in tab order.
    ///   - selectedSurfaceID: The selected surface, if any.
    ///   - selectedStableSurfaceID: The selected surface's restart-stable identity, if any.
    ///   - pixelFrame: The pane's pixel frame, if known.
    ///   - gridSize: The selected surface's grid size, if available.
    ///   - dockScopeRawValue: The Dock scope for a Dock-hosted pane.
    public init(
        paneID: UUID,
        isFocused: Bool,
        surfaceIDs: [UUID],
        stableSurfaceIDs: [UUID] = [],
        selectedSurfaceID: UUID?,
        selectedStableSurfaceID: UUID? = nil,
        pixelFrame: ControlPanePixelFrame?,
        gridSize: ControlPaneGridSize?,
        dockScopeRawValue: String? = nil
    ) {
        self.paneID = paneID
        self.isFocused = isFocused
        self.surfaceIDs = surfaceIDs
        self.stableSurfaceIDs = stableSurfaceIDs
        self.selectedSurfaceID = selectedSurfaceID
        self.selectedStableSurfaceID = selectedStableSurfaceID
        self.pixelFrame = pixelFrame
        self.gridSize = gridSize
        self.dockScopeRawValue = dockScopeRawValue
    }
}
