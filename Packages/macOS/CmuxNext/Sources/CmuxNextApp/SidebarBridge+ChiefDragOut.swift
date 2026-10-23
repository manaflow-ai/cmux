import CmuxNextActions
import CmuxNextSidebar

extension SidebarBridge {
    /// The Chief dropped beside the sidebar comes off it, as its Remove from Sidebar does (Leo 2026-10-21),
    /// whether a band or a group or machine list holds it.
    func wireChiefDragOut() {
        container.sidebarView.removesOnDragOut = { [weak model] id in
            let id = LayoutItemID(id)
            return (model?.layout.item(id) ?? model?.listedItem(id))?.ref == .builtIn(.chief)
        }
        container.sidebarView.onDragOutRemove = { [weak services] id in
            _ = services?.registry.perform("sidebar.item.removeEverywhere",
                                           invocation: ActionInvocation(target: ActionTargetRef(kind: .sidebarItem, id: id), origin: .user))
        }
    }
}
