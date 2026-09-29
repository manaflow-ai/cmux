import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs

/// Chrome-style tab group actions (architecture.md section 7): create,
/// membership, rename, nine colors, collapse, ungroup, close, reorder, move
/// to split/column/workspace/window, new tab in group, and saved groups.
/// All need the daemon's `tab-groups-v1`; without it every action is
/// disabled with that reason.
enum TabGroupHandlers {
    typealias GroupID = CmuxNextDaemon.TabGroupID

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let gate = ctx.needs(DaemonCapabilities.tabGroups)
        func bind(_ id: ActionID, _ invoke: @escaping @MainActor (ActionInvocation) -> Void) {
            registry.bind(id, unavailable: gate, invoke: invoke)
        }
        bindMembership(bind, ctx)
        bindAppearance(bind, ctx)
        bindLifecycle(bind, ctx)
        TabGroupHandlers.bindMoves(bind, ctx)
    }

    typealias Binder = (ActionID, @escaping @MainActor (ActionInvocation) -> Void) -> Void

    // MARK: Resolution

    /// The targeted group (`--target tab-group:<id>` or a `group` argument),
    /// else the group of the targeted or focused tab, with its pane.
    static func group(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> (id: GroupID, pane: PaneModel)? {
        let explicit = [invocation.target, invocation["group"]?.targetValue].compactMap { $0 }.first { $0.kind == .tabGroup }
        if let explicit {
            let id = GroupID(rawValue: explicit.id)
            return pane(holding: id, ctx).map { (id, $0) } ?? ctx.refuse(RefusalStrings.noOpenTabGroup(explicit.id))
        }
        guard let (tab, pane) = ctx.daemonTab(invocation) else { return nil }
        guard let id = tab.tabGroup ?? ctx.refuse(RefusalStrings.tabNotInGroup) else { return nil }
        return (id, pane)
    }

    static func pane(holding group: GroupID, _ ctx: AppActionContext) -> PaneModel? {
        ctx.services.activeDaemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).first { $0.tabGroups.contains { $0.id == group } }
    }

    /// Runs a group command with a transaction and an optimistic patch;
    /// a rejection re-pushes daemon truth into the pane's strip.
    static func run(_ label: String, pane: PaneModel?, patch: OptimisticPatch = .custom { _ in }, _ ctx: AppActionContext,
                    _ body: @escaping @Sendable (DaemonConnection, ClientTransactionID) async throws -> Void) {
        guard ctx.connection() != nil else { return }
        Task {
            let ok = await ctx.services.activeDaemon.perform(label, patch: patch, expectEcho: false, body)
            if !ok, let pane { ctx.services.paneController(for: pane)?.resyncStrip() }
        }
    }

    // MARK: Membership

    private static func bindMembership(_ bind: Binder, _ ctx: AppActionContext) {
        bind("tabGroup.create") { invocation in
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
            guard !tab.pinned else { return ctx.refuse(RefusalStrings.pinnedCannotGroup) }
            let surface = tab.surface, handle = pane.handle
            let name = invocation["name"]?.stringValue
            let color = invocation["color"]?.stringValue ?? GroupColor.grey.rawValue
            run("create-tab-group", pane: pane, ctx) { c, t in
                _ = try await c.createTabGroup(in: handle, tabs: [surface], name: name, color: color, transaction: t)
            }
        }
        bind("tabGroup.addTab") { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return }
            guard let ref = invocation["group"]?.targetValue ?? ctx.refuse(RefusalStrings.groupArgumentRequired) else { return }
            guard !tab.pinned else { return ctx.refuse(RefusalStrings.pinnedCannotGroup) }
            let group = GroupID(rawValue: ref.id), surface = tab.surface
            guard let pane = pane(holding: group, ctx) ?? ctx.refuse(RefusalStrings.noOpenTabGroup(ref.id)) else { return }
            run("add-tabs-to-group", pane: pane, ctx) { c, t in _ = try await c.addTabs([surface], toGroup: group, transaction: t) }
        }
        bind("tabGroup.removeTab") { invocation in
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
            guard tab.tabGroup != nil else { return ctx.refuse(RefusalStrings.tabNotInGroup) }
            let surface = tab.surface
            run("remove-tabs-from-group", pane: pane, ctx) { c, t in _ = try await c.removeTabsFromGroup([surface], transaction: t) }
        }
        bind("tabGroup.newTab") { invocation in
            guard let (group, pane) = group(invocation, ctx) else { return }
            let handle = pane.handle
            let cwd = pane.tabs.last { $0.tabGroup == group }?.cwd
            let controller = ctx.services.paneController(for: pane)
            guard let connection = ctx.connection() else { return }
            Task {
                do {
                    let created = try await connection.newTab(in: handle, options: SpawnOptions(cwd: cwd))
                    _ = try await connection.addTabs([created.surface], toGroup: group)
                    if let controller {
                        controller.pendingSelectSurface = created.surface
                        controller.apply(controller.snapshot())
                    }
                } catch {
                    ctx.services.daemon.logger.error("new-tab-in-group failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: Name, color, collapse

    private static func bindAppearance(_ bind: Binder, _ ctx: AppActionContext) {
        bind("tabGroup.rename") { invocation in
            guard let (group, pane) = group(invocation, ctx) else { return }
            guard let name = invocation["name"]?.stringValue ?? ctx.refuse(RefusalStrings.nameArgumentRequired) else { return }
            run("update-tab-group", pane: pane, ctx) { c, t in _ = try await c.updateTabGroup(group, name: name, transaction: t) }
        }
        bind("tabGroup.setColor") { invocation in
            let raw = invocation["color"]?.stringValue ?? ""
            guard let color = GroupColor(rawValue: raw) else { return ctx.refuse(RefusalStrings.colorArgumentRequired) }
            setColor(color, invocation, ctx)
        }
        for color in GroupColor.allCases {
            bind(ActionID(rawValue: "tabGroup.color.\(color.rawValue)")) { setColor(color, $0, ctx) }
        }
        bind("tabGroup.toggleCollapsed") { setCollapsed(nil, $0, ctx) }
        bind("tabGroup.collapse") { setCollapsed(true, $0, ctx) }
        bind("tabGroup.expand") { setCollapsed(false, $0, ctx) }
    }

    private static func setColor(_ color: GroupColor, _ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let (group, pane) = group(invocation, ctx) else { return }
        run("update-tab-group", pane: pane, ctx) { c, t in _ = try await c.updateTabGroup(group, color: .set(color.rawValue), transaction: t) }
    }

    /// Collapses (moving selection out of the group, like Chrome) or expands.
    private static func setCollapsed(_ value: Bool?, _ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let (group, pane) = group(invocation, ctx) else { return }
        let current = pane.tabGroups.first { $0.id == group }?.collapsed ?? false
        let collapsed = value ?? !current
        guard collapsed != current else { return }
        if collapsed, let controller = ctx.services.paneController(for: pane) {
            let stripGroup = CmuxNextTabs.TabGroupID(group.rawValue)
            if let selected = controller.stripModel.selectedID, controller.stripModel.tab(selected)?.groupID == stripGroup,
               let outside = controller.stripModel.orderedTabs.first(where: { $0.groupID != stripGroup }) {
                controller.select(outside.id)
            }
        }
        run("update-tab-group", pane: pane, patch: .setTabGroupCollapsed(group, collapsed: collapsed), ctx) { c, t in
            _ = try await c.updateTabGroup(group, collapsed: collapsed, transaction: t)
        }
    }

    // MARK: Ungroup, close, saved groups

    private static func bindLifecycle(_ bind: Binder, _ ctx: AppActionContext) {
        bind("tabGroup.ungroup") { invocation in
            guard let (group, pane) = group(invocation, ctx) else { return }
            run("ungroup-tab-group", pane: pane, ctx) { c, t in _ = try await c.ungroupTabGroup(group, transaction: t) }
        }
        bind("tabGroup.close") { invocation in
            guard let (group, pane) = group(invocation, ctx) else { return }
            run("close-tab-group", pane: pane, ctx) { c, t in _ = try await c.closeTabGroup(group, transaction: t) }
        }
        bind("tabGroup.save") { invocation in
            guard let (group, pane) = group(invocation, ctx) else { return }
            run("save-tab-group", pane: pane, ctx) { c, _ in _ = try await c.saveTabGroup(group) }
        }
        bind("tabGroup.unsave") { invocation in
            guard let (group, pane) = group(invocation, ctx) else { return }
            guard ctx.services.activeDaemon.store.savedTabGroups.contains(where: { $0.openGroup == group }) else {
                return ctx.refuse(RefusalStrings.groupNotSaved)
            }
            run("unsave-tab-group", pane: pane, ctx) { c, _ in _ = try await c.unsaveTabGroup(group: group) }
        }
        bind("tabGroup.deleteSaved") { invocation in
            guard let saved = savedGroup(invocation, ctx) else { return }
            let id = saved.id
            run("delete-saved-tab-group", pane: nil, ctx) { c, _ in _ = try await c.deleteSavedTabGroup(id) }
        }
        bind("tabGroup.reopenSaved") { invocation in
            guard let saved = savedGroup(invocation, ctx), let pane = ctx.daemonPane(invocation) else { return }
            guard saved.openGroup == nil else { return ctx.refuse(RefusalStrings.savedGroupAlreadyOpen) }
            let id = saved.id, handle = pane.handle
            run("reopen-saved-tab-group", pane: pane, ctx) { c, t in _ = try await c.reopenSavedTabGroup(id, in: handle, transaction: t) }
        }
    }

    /// A saved group by saved id or by the id of its open group.
    private static func savedGroup(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> SavedTabGroupModel? {
        guard let ref = invocation["group"]?.targetValue ?? ctx.refuse(RefusalStrings.groupArgumentRequired) else { return nil }
        let saved = ctx.services.activeDaemon.store.savedTabGroups
        return saved.first { $0.id.rawValue == ref.id || $0.openGroup?.rawValue == ref.id } ?? ctx.refuse(RefusalStrings.noSavedTabGroup(ref.id))
    }
}
