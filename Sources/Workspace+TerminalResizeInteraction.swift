import Bonsplit

extension Workspace {
    func splitTabBarDividerDragDidBegin(_ controller: BonsplitController) {
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
    }

    func splitTabBarDividerDragDidEnd(_ controller: BonsplitController) {
        TerminalWindowPortalRegistry.endInteractiveGeometryResize()
    }
}
