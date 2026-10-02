import CmuxNextActions
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextSidebar
import Observation

// Sidebar sections (plans/cmux-next/sidebar-sections.md): built-in items
// run their registry action as the user; pinned workspaces select. Layout
// ops go to the workspace store once it serves `sidebar-layout-v1`; until
// then they are refused, except in DEV with the local prototype switch,
// which edits the in-memory layout (never saved).
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
        sectionsObservation = Task { [weak self] in
            for await layout in Observations({ model.layout }) {
                guard self != nil else { return }
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

    func applyLayoutOp(_ op: SidebarLayoutOp) {
        guard DevTools.isEnabled, SidebarSectionTunables.localPrototype.override == true else { return }
        model.apply(.layout(op))
    }
}
