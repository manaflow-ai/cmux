import AppKit
import CmuxSwiftRender

/// Retained (via the owning `NSMenuItem.representedObject`) target that
/// forwards a menu item's activation to the sidebar action dispatch.
@MainActor
final class RenderMenuItemTarget: NSObject {
    private nonisolated let action: ButtonAction
    private nonisolated let dispatch: SidebarActionDispatch

    init(action: ButtonAction, dispatch: SidebarActionDispatch) {
        self.action = action
        self.dispatch = dispatch
    }

    @objc nonisolated func fire(_ sender: Any?) {
        let action = self.action
        let dispatch = self.dispatch
        // Menu item actions arrive on the main thread.
        MainActor.assumeIsolated {
            dispatch.run(action)
        }
    }
}
