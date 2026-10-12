import AppKit
import CmuxNextBridge
import CmuxNextLayout
import CmuxNextTabs

/// Drag a pane by its tab bar onto another pane to swap them (cx-8bv1j).
@MainActor
final class PaneSwapDrag: NSObject {
    init(strip: TabStripView, pane: LayoutPaneID, layout: @escaping () -> LayoutRootView?,
         swap: @escaping (LayoutPaneID, LayoutPaneID) -> Void) {}
}
