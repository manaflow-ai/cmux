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

extension SidebarBridge {
    /// The item menu rows an item `id` does not offer while its add waits for the daemon (a Chief just dragged in): an
    /// edit of its own fields waits for the echo (the planner refuses it until then), so the menu leaves it out.
    static func pendingEdits(_ id: LayoutItemID) -> Set<ActionID> {
        SidebarDocStore.current?.isPending(id) == true ? ["sidebar.item.toggleLabel"] : []
    }
}
