import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// Workspace verbs that create or place workspaces and move between them
/// (REWRITE.md round 3, "Workspace verbs"). Placement goes through the
/// workspace's window sidebar (`SidebarBridge`), the path a row drag takes:
/// personal order in the home session when it serves personal state, else
/// `move-workspace-to-group` on the owning daemon.
enum WorkspaceVerbHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("workspace.newAbove", run: { try create(context, $0) { .above($0.id) } })
        // On one of several selected rows: below the last of them (Chrome's New Tab Below).
        registry.bind("workspace.newBelow", run: { invocation in
            let anchor = try WindowMembershipHandlers.rowTargets(invocation, context).last ?? context.workspace(invocation).model
            try spawn(context, anchor: anchor, cwd: nil, slot: .below(anchor.id), newTabPage: invocation.origin == .user)
        })
        registry.bind("workspace.newAtTop", run: { try create(context, $0, anchorFree: .top(anchor: nil)) })
        registry.bind("workspace.newAtBottom", run: { try create(context, $0, anchorFree: .bottom(anchor: nil)) })
        // Its directory, its place (below it, so in its group) and its first tab's kind
        // (cmuxterm-hq#1829); also what New Workspace in This Group and in Same Directory ran.
        registry.bind("workspace.newLikeThis", run: { invocation in
            let anchor = try context.workspace(invocation).model
            let cwd = directory(of: anchor, context)
            let first = firstTab(like: anchor, cwd: cwd, user: invocation.origin == .user, context)
            try spawn(context, anchor: anchor, cwd: cwd, slot: .below(anchor.id), newTabPage: first.newTabPage, firstChat: first.chat)
        })
        registry.bind("workspace.newInNewGroup", run: { invocation in
            let name = invocation["name"]?.stringValue ?? ""
            let byUser = invocation.origin == .user
            // The group forms last in its section in one write, where the store lists a new
            // group, not at the row's daemon slot first (no slide, cx-f6i7); no reorder races it.
            try create(context, invocation, anchorFree: nil) { id, bridge in
                guard let bridge = bridge as? SidebarBridge else { return }
                bridge.groupFlow.newGroup(of: [SidebarWorkspaceID(id)], name: name, byUser: byUser, index: .max)
            }
        })
        registry.bind("workspace.newOnMachine", run: { invocation in
            guard let machine = invocation["machine"]?.targetValue?.id ?? invocation["machine"]?.stringValue,
                  let daemon = context.services.machines.daemon(machine: machine) else {
                throw ActionFailure.invalidTarget(WorkspaceVerbStrings.noMachine)
            }
            guard daemon.connection != nil else { throw ActionFailure.invalidTarget(WorkspaceVerbStrings.machineNotConnected) }
            newWorkspace(on: daemon, invocation, context)
        })

        // Top or bottom of the row's container: its group, else the loose rows. A grouped row's
        // menu says so ("Move to Top of Group", u2418); a multi-selection moves as one block.
        registry.bind("palette.moveWorkspaceToTop", run: { try place(context, $0) { .top(anchor: $0.id) } })
        registry.bind("workspace.moveToBottom", run: { try place(context, $0) { .bottom(anchor: $0.id) } })
        ActionTargetTitles.set("palette.moveWorkspaceToTop", in: registry) { invocation in
            isGrouped(invocation, context) ? WorkspaceVerbStrings.moveToTopOfGroup : nil
        }
        ActionTargetTitles.set("workspace.moveToBottom", in: registry) { invocation in
            isGrouped(invocation, context) ? WorkspaceVerbStrings.moveToBottomOfGroup : nil
        }
        registry.bind("workspace.moveToNewGroup", run: { invocation in
            let workspace = try context.workspace(invocation).model
            let ids = try WindowMembershipHandlers.workspaces(invocation, context).map(SidebarWorkspaceID.init)
            try sidebar(showing: workspace, context).groupFlow.newGroup(of: ids, name: invocation["name"]?.stringValue ?? "",
                                                              byUser: invocation.origin == .user)
        })

        registry.bind("workspace.selectFirst", run: { _ in try select(context) { $0.first } })
        registry.bind("workspace.selectLast", run: { _ in try select(context) { $0.last } })
        registry.bind("workspace.selectLastUsed", run: { _ in
            guard let window = context.activeWindow else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
            let listed = Set(window.sidebar.model.allWorkspaces.map(\.id.rawValue))
            window.state.pruneRecency(keeping: listed)
            guard let previous = window.state.lastUsedWorkspace else { throw ActionFailure.invalidTarget(WorkspaceVerbStrings.noLastUsed) }
            context.services.windows.show(workspaceID: previous, in: window.state)
        })
        for key in WorkspaceSortKey.allCases {
            let suffix = key.rawValue.prefix(1).uppercased() + key.rawValue.dropFirst()
            registry.bind(ActionID(rawValue: "workspace.sortBy" + suffix), run: { _ in try sort(by: key, context) })
            // The same sort, on the targeted group's members only.
            registry.bind(ActionID(rawValue: "workspaceGroup.sortBy" + suffix), run: { invocation in
                try sort(by: key, only: context.sidebar().model.groupID(personal: context.group(invocation).id.rawValue), context)
            })
        }
        registry.bind("workspaceGroup.collapseAll", run: { _ in try setAllCollapsed(true, context) })
        registry.bind("workspaceGroup.expandAll", run: { _ in try setAllCollapsed(false, context) })
    }

    // MARK: Create

    /// New workspace (on the New Tab page for a person, else one terminal)
    /// next to the target workspace: in its window and on its machine,
    /// placed at `slot` once the daemon reports it.
    private static func create(_ context: AppActionContext, _ invocation: ActionInvocation, cwd: String? = nil,
                               _ slot: (WorkspaceModel) throws -> WorkspaceSlot) throws {
        let anchor = try context.workspace(invocation).model
        try spawn(context, anchor: anchor, cwd: cwd, slot: try slot(anchor), newTabPage: invocation.origin == .user)
    }

    /// New workspace in the target workspace's window (else the active
    /// one) at an anchor-free `slot`; `then` runs once it is listed.
    static func create(_ context: AppActionContext, _ invocation: ActionInvocation, anchorFree slot: WorkspaceSlot?,
                               then: (@MainActor @Sendable (String, any WorkspaceSpawnSidebar) -> Void)? = nil) throws {
        try spawn(context, anchor: try? context.workspace(invocation).model, cwd: nil, slot: slot, newTabPage: invocation.origin == .user,
                  then: then)
    }

    private static func spawn(_ context: AppActionContext, anchor: WorkspaceModel?, cwd: String?, slot: WorkspaceSlot?,
                              newTabPage: Bool, firstChat: AgentPaneSeed? = nil,
                              then: (@MainActor @Sendable (String, any WorkspaceSpawnSidebar) -> Void)? = nil) throws {
        let windows = context.services.windows
        let window = anchor.flatMap { windows.registry.value.owner(of: $0.id) } ?? context.activeWindow?.state.id
        let target = windows.targetWindow(preferring: window)
        var spawn = WorkspaceSpawn(cwd: cwd)
        spawn.slot = slot
        spawn.onListed = then
        // `then` places it itself (New Workspace in New Group): no second write.
        spawn.placesBySetting = then == nil
        spawn.opensNewTabPage = newTabPage
        spawn.firstChat = firstChat
        let daemon = anchor.flatMap { context.services.machines.daemon(forWorkspace: $0.id) }
        context.services.registry.track(Task {
            do {
                _ = try await windows.createWorkspace(spawn, on: daemon, into: target)
                return nil
            } catch {
                return ActionWorkFailure("new workspace", error)
            }
        })
    }

    /// New Workspace on Machine: a new workspace on `daemon` in the active window, born in that
    /// window's room so it shows even when the room does not follow the machine's session
    /// (data-model.md 3.2). A person gets the New Tab page; a CLI, MCP or script run gets a
    /// terminal and waits for the create, so `action.run` answers with what it made
    /// (``createdFields``) and lists it in `created`.
    static func newWorkspace(on daemon: DaemonService, _ invocation: ActionInvocation, _ context: AppActionContext) {
        let services = context.services, windows = services.windows
        let target = windows.targetWindow(preferring: context.activeWindow?.state.id)
        let spawn = WorkspaceSpawn(newTabPage: invocation.origin == .user)
        services.registry.track(result: Task {
            do {
                let id = try await windows.createWorkspace(spawn, on: daemon, into: target)
                // The store lists it (its `ws_` id and name) once it applied the create's events.
                if let connection = daemon.connection { await daemon.appliedThroughReply(on: connection, after: "new workspace on machine") }
                return .success(createdFields(id, on: daemon, services: services))
            } catch {
                daemon.logger.error("create workspace failed: \(String(describing: error), privacy: .public)")
                return .failure(ActionWorkFailure("new workspace on machine", error))
            }
        })
    }

    /// `action.run`'s `result` for a workspace made on `daemon`: its public id (`ws_…` on
    /// registry daemons, else its key), its name once the store lists it, and the machine.
    static func createdFields(_ id: String, on daemon: DaemonService, services: AppServices) -> [String: ActionResultValue] {
        let workspace = services.workspace(id: id)
        var fields: [String: ActionResultValue] = [
            "workspace_id": .string(workspace?.resourceID?.rawValue ?? id),
            "machine_id": .string(daemon.machineID),
        ]
        if let workspace { fields["name"] = .string(workspace.displayName) }
        return fields
    }

    /// The first tab of a workspace like `anchor`, by the kind of its first tab: a terminal, the
    /// New Tab page or a new agent chat in `cwd`. A browser tab has no first-tab spawn: the
    /// New Tab page for a person, else a terminal, as for an empty workspace.
    private static func firstTab(like anchor: WorkspaceModel, cwd: String?, user: Bool,
                                 _ context: AppActionContext) -> (newTabPage: Bool, chat: AgentPaneSeed?) {
        guard let tab = anchor.screens.first?.panes.first?.tabs.first else { return (user, nil) }
        switch NewTabKind.of(tab.id, tab: tab, services: context.services) {
        case .terminal: return (false, nil)
        case .page: return (true, nil)
        case .agent: return (false, AgentPaneSeed(cwd: cwd))
        case .browser: return (user, nil)
        }
    }

    // MARK: Place

    /// Moves the target workspace, or the multi-selection it belongs to, to
    /// `slot` in its window's sidebar, with the sidebar's optimistic update.
    private static func place(_ context: AppActionContext, _ invocation: ActionInvocation, _ slot: (WorkspaceModel) -> WorkspaceSlot) throws {
        let workspace = try context.workspace(invocation).model
        let ids = try WindowMembershipHandlers.workspaces(invocation, context)
        guard place(ids, anchor: workspace, slot(workspace), in: try sidebar(showing: workspace, context), services: context.services)
        else { throw ActionFailure.invalidTarget(RefusalStrings.workspaceNotInSidebar) }
    }

    /// Moves `workspace` to `slot` in `bridge`'s sidebar, as the Move
    /// Workspace verbs do; false when that sidebar does not list it.
    @discardableResult
    static func place(_ workspace: WorkspaceModel, _ slot: WorkspaceSlot, in bridge: SidebarBridge, services: AppServices) -> Bool {
        place([workspace.id], anchor: workspace, slot, in: bridge, services: services)
    }

    /// Moves `ids` (rows of `anchor`'s section; others stay) to `slot`, which names
    /// `anchor`'s container, as one block in sidebar order. False when `bridge`'s
    /// sidebar does not list `anchor`: the move would land it loose, out of its group.
    @discardableResult
    static func place(_ ids: [String], anchor workspace: WorkspaceModel, _ slot: WorkspaceSlot, in bridge: SidebarBridge,
                      services: AppServices) -> Bool {
        let sections = bridge.model.sections, anchor = SidebarWorkspaceID(workspace.id)
        guard services.machines.daemon(forWorkspace: workspace.id) != nil,
              let home = SidebarEdits.locate(anchor, in: sections)?.section else { return false }
        var moving = SidebarEdits.treeOrder(ids.map(SidebarWorkspaceID.init), in: sections).filter {
            SidebarEdits.locate($0, in: sections)?.section == home
        }
        if moving.isEmpty { moving = [anchor] }
        guard let position = slot.position(moving: Set(moving.map(\.rawValue)), besides: workspace.id, in: sections)
        else { return false }
        // Pinned and custom sections move only on the sidebar document; off it, a reorder there would pin the rows.
        if sections[home].machine == nil, !SidebarDocWiring.isActive { return false }
        bridge.handle(.reorder(moving, to: position))
        return true
    }

    /// Whether the targeted workspace sits in a group of its window's sidebar.
    private static func isGrouped(_ invocation: ActionInvocation, _ context: AppActionContext) -> Bool {
        guard let workspace = try? context.workspace(invocation).model else { return false }
        return (try? group(of: workspace, context)) != nil
    }

    /// The sidebar of the window that lists `workspace`, else the active one.
    static func sidebar(showing workspace: WorkspaceModel, _ context: AppActionContext) throws -> SidebarBridge {
        let windows = context.services.windows
        if let owner = windows.registry.value.owner(of: workspace.id), let controller = windows.controller(for: owner) { return controller.sidebar }
        return try context.sidebar()
    }

    /// The sidebar group listing `workspace` in its window, if any.
    static func group(of workspace: WorkspaceModel, _ context: AppActionContext) throws -> SidebarGroup? {
        let sections = try sidebar(showing: workspace, context).model.sections
        for section in sections {
            for case let .group(group) in section.nodes where group.workspaces.contains(where: { $0.id.rawValue == workspace.id }) {
                return group
            }
        }
        return nil
    }

    /// The directory of the workspace's focused terminal, else its first one.
    static func directory(of workspace: WorkspaceModel, _ context: AppActionContext) -> String? {
        let terminals = workspace.screens.flatMap(\.panes).flatMap(\.tabs).filter { $0.kind == .pty }
        if let window = context.activeWindow, window.state.workspaceID == workspace.id, let pane = window.focusedPane,
           let selected = pane.stripModel.selectedID, let tab = terminals.first(where: { $0.id == selected.rawValue }), let cwd = tab.cwd {
            return cwd
        }
        return terminals.lazy.compactMap(\.cwd).first
    }

    // MARK: Close, select, sort, collapse

    private static func select(_ context: AppActionContext, _ pick: ([SidebarWorkspaceID]) -> SidebarWorkspaceID?) throws {
        guard let window = context.activeWindow else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
        guard let id = pick(window.sidebar.model.selectableWorkspaces.map(\.id)) else { throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn) }
        context.services.windows.show(workspaceID: id.rawValue, in: window.state)
    }

    /// Sorts every container (the loose rows, each group) of the active
    /// window's sidebar, or only group `only`; groups keep their place and members.
    private static func sort(by key: WorkspaceSortKey, only: GroupID? = nil, _ context: AppActionContext) throws {
        guard let window = context.activeWindow else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
        let bridge = window.sidebar
        let before = bridge.model.sections
        var names: [String: String] = [:], directories: [String: String] = [:]
        for workspace in bridge.model.allWorkspaces {
            let id = workspace.id.rawValue
            names[id] = workspace.title
            if let model = context.services.workspace(id: id) { directories[id] = directory(of: model, context) }
        }
        for section in before where section.machine != nil {
            for (group, ids) in WorkspaceSortKey.containers(of: section, only: only) where ids.count > 1 {
                let sorted = key.sorted(ids, names: names, directories: directories, recency: window.state.workspaceRecency)
                guard sorted != ids else { continue }
                let moving = sorted.map(SidebarWorkspaceID.init)
                // Optimistic: one row at a time, so the preview is sorted too.
                for (index, id) in moving.enumerated() {
                    bridge.model.apply(.reorder([id], to: DropPosition(section: section.id, group: group, index: index)))
                }
                bridge.place(moving, at: DropPosition(section: section.id, group: group, index: 0), in: before)
            }
        }
    }

    private static func setAllCollapsed(_ collapsed: Bool, _ context: AppActionContext) throws {
        let bridge = try context.sidebar()
        for section in bridge.model.sections {
            for case let .group(group) in section.nodes where group.isCollapsed != collapsed {
                bridge.handle(.toggleCollapse(.group(group.id)))
            }
        }
    }
}
