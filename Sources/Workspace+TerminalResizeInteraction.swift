import AppKit
import Bonsplit

extension Workspace {
    func splitTabBarDividerDragDidBegin(_ controller: BonsplitController) {
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(
            owner: controller,
            in: terminalResizeInteractionWindow()
        )
    }

    func splitTabBarDividerDragDidEnd(_ controller: BonsplitController) {
        TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: controller)
    }

    private func terminalResizeInteractionWindow() -> NSWindow? {
        if let eventWindow = NSApp.currentEvent?.window { return eventWindow }
        return panels.values.lazy.compactMap { panel in
            (panel as? TerminalPanel)?.hostedView.window
        }.first
    }
}
