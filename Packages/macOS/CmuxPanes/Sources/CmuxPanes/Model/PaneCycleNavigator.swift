public import Bonsplit
public import Foundation

/// Resolves wrapping previous/next pane focus targets from a stable pane order.
public struct PaneCycleNavigator {
    /// Creates a stateless pane-cycle navigator.
    public init() {}

    /// Returns the pane reached by cycling one step from the currently focused pane.
    ///
    /// `orderedPaneIds` is the authoritative visual/tree order. `livePaneIds`
    /// is the controller's current pane set, used to discard stale ordered ids
    /// before indexing and to return the concrete `PaneID` value the controller
    /// expects.
    ///
    /// - Parameters:
    ///   - orderedPaneIds: Pane UUIDs in stable visual/tree order.
    ///   - livePaneIds: Pane ids currently owned by the split controller.
    ///   - focusedPaneId: The currently focused pane.
    ///   - forward: `true` for next, `false` for previous.
    /// - Returns: The target pane, or `nil` when cycling is not possible.
    public func targetPane(
        orderedPaneIds: [UUID],
        livePaneIds: [PaneID],
        focusedPaneId: PaneID?,
        forward: Bool
    ) -> PaneID? {
        var panesById: [UUID: PaneID] = [:]
        for paneId in livePaneIds {
            panesById[paneId.id] = paneId
        }

        let orderedLivePaneIds = orderedPaneIds.compactMap { panesById[$0] }
        guard orderedLivePaneIds.count > 1,
              let focusedPaneId,
              let currentIndex = orderedLivePaneIds.firstIndex(of: focusedPaneId) else {
            return nil
        }

        let targetIndex = forward
            ? (currentIndex + 1) % orderedLivePaneIds.count
            : (currentIndex - 1 + orderedLivePaneIds.count) % orderedLivePaneIds.count
        return orderedLivePaneIds[targetIndex]
    }
}
