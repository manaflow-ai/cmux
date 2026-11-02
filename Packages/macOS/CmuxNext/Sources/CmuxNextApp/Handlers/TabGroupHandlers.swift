import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextTabs

/// Tab group actions (architecture.md section 7): create,
/// membership, rename, nine colors, collapse, ungroup, close, reorder, move
/// to split/column/workspace/window, new tab in group, and saved groups.
/// All need the daemon's `tab-groups-v1`; without it every action is
/// disabled with that reason.
enum TabGroupHandlers {
    typealias GroupID = CmuxNextDaemon.TabGroupID

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let gate = ctx.needs(DaemonCapability.tabGroups.rawValue)
        func bind(_ id: ActionID, _ invoke: @escaping @MainActor (ActionInvocation) -> Void) {
            registry.bind(id, unavailable: gate, invoke: invoke)
        }
        bindMembership(bind, ctx)
        ActionTargetVisibility.hide("tabGroup.removeTab", in: registry) { run in run.target.flatMap { $0.kind == .tab ? ctx.targetTab($0.id, run) : nil }.map { $0.0.tabGroup == nil } ?? false }
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

    /// The connection of `pane`'s own daemon; refuses (daemon offline) without one.
    static func connection(for pane: PaneModel, _ ctx: AppActionContext) -> DaemonConnection? {
        ctx.services.daemon(for: pane).connection ?? ctx.refuse(MiscHandlerStrings.daemonOffline)
    }

    /// The pane holding `group`, on whichever machine owns it (`GroupOwnership`).
    static func pane(holding group: GroupID, _ ctx: AppActionContext) -> PaneModel? {
        GroupOwnership.pane(holdingTabGroup: group, machines: ctx.services.machines)?.pane
    }

    /// Runs a group command with a transaction, shown at once through the
    /// store's intent log when it has an `intent`; a rejection re-pushes
    /// daemon truth into the pane's strip.
    static func run(_ label: String, pane: PaneModel?, intent: Intent? = nil, _ ctx: AppActionContext,
                    _ body: @escaping @Sendable (DaemonConnection, ClientTransactionID) async throws -> Void) {
        // The pane's own machine, not the active window's daemon.
        let daemon = pane.map { ctx.services.daemon(for: $0) } ?? ctx.services.activeDaemon
        guard daemon.connection ?? ctx.refuse(MiscHandlerStrings.daemonOffline) != nil else { return }
        Task {
            let ok = await daemon.runGroupCommand(label, intent: intent, body)
            if !ok, let pane { ctx.services.paneController(for: pane)?.resyncStrip() }
        }
    }

    // MARK: Membership

    private static func bindMembership(_ bind: Binder, _ ctx: AppActionContext) {
        // Each acts on the targeted (or focused) tab and the rest of its strip's multi-selection
        // (`AppActionContext.actionTabs`), the same tabs from the tab menu, the palette, a shortcut and the CLI.
        bind("tabGroup.create") { invocation in
            guard let (selected, pane) = ctx.actionTabs(invocation) else { return }
            let tabs = selected.filter { !$0.pinned }
            guard !tabs.isEmpty else { return ctx.refuse(RefusalStrings.pinnedCannotGroup) }
            let name = invocation["name"]?.stringValue
            // The same color rule as screen groups (`TabGroupOrdering.nextColor`).
            let color = invocation["color"]?.stringValue
                ?? TabGroupOrdering.nextColor(used: pane.tabGroups.compactMap { $0.color.flatMap(GroupColor.init(rawValue:)) }).rawValue
            let writes = TabGroupWrites(pane: pane, daemon: ctx.services.daemon(for: pane))
            run("create-tab-group", pane: pane, ctx, writes.create(tabs, name: name, color: color))
            ctx.services.paneController(for: pane)?.stripModel.clearMultiSelection()
        }
        bind("tabGroup.addTab") { invocation in
            guard let (selected, _) = ctx.actionTabs(invocation) else { return }
            guard let ref = invocation["group"]?.targetValue ?? ctx.refuse(RefusalStrings.groupArgumentRequired) else { return }
            let tabs = selected.filter { !$0.pinned }
            guard let first = tabs.first ?? ctx.refuse(RefusalStrings.pinnedCannotGroup) else { return }
            let group = GroupID(rawValue: ref.id)
            guard let pane = pane(holding: group, ctx) ?? ctx.refuse(RefusalStrings.noOpenTabGroup(ref.id)) else { return }
            // The tabs must be on the group's machine (surface ids are per daemon).
            guard GroupOwnership.owner(ofTabGroup: group, sameMachineAs: ctx.services.machines.daemon(forTab: first),
                                       machines: ctx.services.machines) != nil else { return ctx.refuse(RefusalStrings.otherMachine) }
            let writes = TabGroupWrites(pane: pane, daemon: ctx.services.daemon(for: pane))
            run("add-tabs-to-group", pane: pane, ctx, writes.add(tabs, to: group))
        }
        bind("tabGroup.removeTab") { invocation in
            guard let (selected, pane) = ctx.actionTabs(invocation) else { return }
            let tabs = selected.filter { $0.tabGroup != nil }
            guard !tabs.isEmpty else { return ctx.refuse(RefusalStrings.tabNotInGroup) }
            let writes = TabGroupWrites(pane: pane, daemon: ctx.services.daemon(for: pane))
            run("remove-tabs-from-group", pane: pane, ctx, writes.remove(tabs))
        }
        bind("tabGroup.newTab") { invocation in
            guard let (group, pane) = group(invocation, ctx) else { return }
            let handle = pane.handle
            let cwd = pane.tabs.last { $0.tabGroup == group }?.cwd
            let controller = ctx.services.paneController(for: pane)
            let workspace = ctx.services.workspaceKey(of: pane)
            guard let connection = connection(for: pane, ctx) else { return }
            let logger = ctx.services.daemon(for: pane).logger
            Task {
                do {
                    let created = try await connection.newTab(in: handle, options: SpawnOptions(cwd: cwd, workspace: workspace))
                    _ = try await connection.addTabs([created.surface], toGroup: group)
                    if let controller {
                        controller.selectWhenReported(surface: created.surface)
                        controller.workspace?.expectFocus(on: created.surface)
                    }
                } catch {
                    logger.error("new-tab-in-group failed: \(String(describing: error), privacy: .public)")
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
            // The catalog offers palette tokens; read as a tint so a custom `#RRGGBB` (cx-wqn5) also lands.
            guard let tint = GroupTint(wire: invocation["color"]?.stringValue ?? "") else {
                return ctx.refuse(RefusalStrings.colorArgumentRequired)
            }
            setColor(tint, invocation, ctx)
        }
        for color in GroupColor.allCases {
            bind(ActionID(rawValue: "tabGroup.color.\(color.rawValue)")) { setColor(.palette(color), $0, ctx) }
        }
        bind("tabGroup.toggleCollapsed") { setCollapsed(nil, $0, ctx) }
        bind("tabGroup.collapse") { setCollapsed(true, $0, ctx) }
        bind("tabGroup.expand") { setCollapsed(false, $0, ctx) }
    }

    private static func setColor(_ tint: GroupTint, _ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let (group, pane) = group(invocation, ctx) else { return }
        run("update-tab-group", pane: pane, ctx) { c, t in _ = try await c.updateTabGroup(group, color: .set(tint.wire), transaction: t) }
    }

    /// Collapses (moving selection out of the group) or expands.
    private static func setCollapsed(_ value: Bool?, _ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let (group, pane) = group(invocation, ctx) else { return }
        let current = pane.tabGroups.first { $0.id == group }?.collapsed ?? false
        let collapsed = value ?? !current
        guard collapsed != current else { return }
        if collapsed, let controller = ctx.services.paneController(for: pane) {
            // The collapse rule (`TabGroupOrdering`), shared with screen groups.
            let strip = controller.stripModel
            let stripGroup = CmuxNextTabs.TabGroupID(group.rawValue)
            let collapsedGroups = Set(strip.groups.filter(\.isCollapsed).map(\.id))
            if let next = TabGroupOrdering.selectionBeforeCollapsing(stripGroup, in: strip.orderedTabs, collapsed: collapsedGroups,
                                                                    selected: strip.selectedID) {
                controller.select(next)
            }
        }
        run("update-tab-group", pane: pane, intent: .setTabGroupCollapsed(group, collapsed: collapsed), ctx) { c, t in
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
            guard let (group, pane) = group(invocation, ctx), connection(for: pane, ctx) != nil else { return }
            // The daemon's group-close event arrives after the request. Move
            // focus out of the group at the press, like a browser closes the
            // selected tab immediately; otherwise the pane keeps presenting a
            // tab that is already on its way out until the tree delta lands.
            if let controller = ctx.services.paneController(for: pane),
               let selected = controller.stripModel.selectedID,
               controller.stripModel.tab(selected)?.groupID == CmuxNextTabs.TabGroupID(group.rawValue) {
                let ordered = controller.stripModel.orderedTabs
                let surviving = ordered.filter { $0.groupID != CmuxNextTabs.TabGroupID(group.rawValue) }
                let collapsed = Set(controller.stripModel.groups.filter(\.isCollapsed).map(\.id))
                let hidden = Set(surviving.filter { $0.groupID.map(collapsed.contains) ?? false }.map(\.id))
                let opener = ctx.services.cache.pageRequests.openers.relations(among: pane.tabs).reduce(into: [CmuxNextTabs.TabID: CmuxNextTabs.TabID]()) { $0[CmuxNextTabs.TabID($1.key)] = CmuxNextTabs.TabID($1.value) }
                if let next = FocusAfterClose.tab(selected: selected, old: ordered.map(\.id), surviving: surviving.map(\.id), shown: Set(surviving.map(\.id)).subtracting(hidden), opener: opener) {
                    controller.select(next)
                }
            }
            let close = { run("close-tab-group", pane: pane, ctx) { c, t in _ = try await c.closeTabGroup(group, transaction: t) } }
            guard CloseUndoToasts.isUserClose, let undo = ctx.services.closedTabs?.undoToasts else { return close() }
            // One undo toast for the group (REOPEN-CLOSED), decided before the close ends its terminals (cx-lb4al).
            let tabs = pane.tabs.filter { $0.tabGroup == group }, window = ctx.services.windows.active?.window
            undo.decideFirst(tabs, on: ctx.services.daemon(for: pane)) { undo.expectGroup(tabs: tabs, in: pane, window: window, costly: $0); close() }
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
