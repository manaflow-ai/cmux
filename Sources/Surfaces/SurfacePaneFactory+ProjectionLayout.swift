import AppKit
import Bonsplit
import Foundation

extension SurfacePaneFactory {
    /// Sets each local divider to the ratio the machine screen had, walking the workspace's
    /// live Bonsplit tree in step with the layout the catalog just built (the traversal
    /// `Workspace.applyCustomLayout` uses for cmux.json layouts). Any shape mismatch — a
    /// split the projection could not create, an orientation that differs — stops that
    /// branch: a ratio is never applied to a divider the layout did not describe.
    static func applyDividerRatios(_ layout: SurfaceProjectionLayout, in workspaceID: UUID) {
        guard let workspace = AppDelegate.shared?.tabManagerFor(tabId: workspaceID)?.tabs.first(where: { $0.id == workspaceID }) else {
            return
        }
        let controller = workspace.bonsplitController
        apply(layout, to: controller.treeSnapshot(), controller: controller)
    }

    private static func apply(_ layout: SurfaceProjectionLayout, to live: ExternalTreeNode, controller: BonsplitController) {
        guard case .split(let direction, let ratio, let first, let second) = layout,
              case .split(let liveSplit) = live,
              liveSplit.orientation == orientationName(direction) else {
            return
        }
        if let splitID = UUID(uuidString: liveSplit.id) {
            _ = controller.setDividerPosition(CGFloat(ratio), forSplit: splitID, fromExternal: true)
        }
        apply(first, to: liveSplit.first, controller: controller)
        apply(second, to: liveSplit.second, controller: controller)
    }

    /// Bonsplit's `ExternalSplitNode.orientation` words: side by side is `horizontal`,
    /// stacked is `vertical` (`vendor/bonsplit` `SplitOrientation`).
    private static func orientationName(_ direction: SurfaceSplitDirection) -> String {
        switch direction {
        case .left, .right: return "horizontal"
        case .up, .down: return "vertical"
        }
    }
}
