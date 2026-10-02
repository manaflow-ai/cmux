import CmuxNextActions
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextSidebar
import Observation

// Sidebar sections (plans/cmux-next/sidebar-sections.md): every window
// draws `SidebarLayoutService.document`; built-in items run their registry
// action as the user; pinned workspaces select; layout ops go to the
// service, which refuses them until the store serves `sidebar-layout-v1`.
extension SidebarBridge {
    /// The registry action each built-in runs.
    static let builtInActions: [SidebarBuiltIn: ActionID] = [
        .home: "home.show",
        .settings: "openSettings",
        .account: "accounts.show",
        .notifications: "showNotifications",
        .history: "history.show",
        .bookmarks: "bookmark.manager",
    ]

    func activateLayoutItem(_ id: LayoutItemID) {
        guard let item = model.layout.item(id) else { return }
        if let builtIn = item.ref.builtIn, let action = Self.builtInActions[builtIn] {
            _ = services.registry.perform(action, invocation: ActionInvocation(origin: .user))
        } else if item.ref.kind == LayoutItemRef.workspaceKind {
            handle(.select(SidebarWorkspaceID(item.ref.value)))
        }
    }

    /// Keeps `model.itemInfo` current: a built-in whose action this build
    /// does not register draws dimmed.
    func observeSections() {
        let model = model
        let registry = services.registry
        // task-owner: the bridge (cancelled in teardown); event-driven (Observation)
        let service = services.sidebarLayout
        sectionsObservation = Task { [weak self] in
            for await layout in Observations({ service.document }) {
                guard self != nil else { return }
                if model.layout != layout { model.layout = layout }
                let infos = Self.itemInfo(for: layout) { registry.action(for: $0) != nil }
                if model.itemInfo != infos { model.itemInfo = infos }
            }
        }
    }

    /// Presentation of every built-in item in `layout`; `registered` says
    /// whether an action exists.
    static func itemInfo(for layout: SidebarLayoutDocument, registered: (ActionID) -> Bool) -> [LayoutItemID: SidebarItemInfo] {
        var infos: [LayoutItemID: SidebarItemInfo] = [:]
        for section in layout.sections {
            for item in section.items {
                guard let builtIn = item.ref.builtIn else { continue }
                var info = builtIn.defaultInfo
                info.isMissing = !(builtInActions[builtIn].map(registered) ?? false)
                infos[item.id] = info
            }
        }
        return infos
    }

    /// A layout change from this sidebar (a drag, an inline edit): sent to
    /// the layout owner; a refusal shows in the refusal HUD.
    func applyLayoutOp(_ op: SidebarLayoutOp) {
        do { try services.sidebarLayout.send(op) } catch { services.registry.refuse(String(describing: error)) }
    }
}
