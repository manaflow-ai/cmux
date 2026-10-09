import AppKit
import CmuxNextActions
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
        registry.bind("workspace.newBelow", run: { try create(context, $0) { .below($0.id) } })
        registry.bind("workspace.newAtTop", run: { try create(context, $0, anchorFree: .top(anchor: nil)) })
        registry.bind("workspace.newAtBottom", run: { try create(context, $0, anchorFree: .bottom(anchor: nil)) })
        registry.bind("workspace.newInGroup", run: { invocation in
            try create(context, invocation) { workspace in
                guard let group = try group(of: workspace, context) else { throw ActionFailure.invalidTarget(RefusalStrings.workspaceNotInGroup) }
                return .endOfGroup(group.id)
            }
        })
        registry.bind("workspace.newInNewGroup", run: { invocation in
            let name = invocation["name"]?.stringValue ?? ""
            try create(context, invocation, anchorFree: nil) { id, bridge in
                bridge.handle(.createGroup(.make(), name: name, color: .grey, workspaces: [SidebarWorkspaceID(id)]))
            }
        })
        registry.bind("workspace.newInSameDirectory", run: { invocation in
            let workspace = try context.workspace(invocation).model
            guard let cwd = directory(of: workspace, context) else { throw ActionFailure.invalidTarget(WorkspaceVerbStrings.noDirectory) }
            try create(context, invocation, cwd: cwd) { .below($0.id) }
        })
        registry.bind("workspace.newOnMachine", run: { invocation in
            guard let machine = invocation["machine"]?.targetValue?.id ?? invocation["machine"]?.stringValue,
                  let daemon = context.services.machines.daemon(machine: machine) else {
                throw ActionFailure.invalidTarget(WorkspaceVerbStrings.noMachine)
            }
            guard daemon.connection != nil else { throw ActionFailure.invalidTarget(WorkspaceVerbStrings.machineNotConnected) }
            // Born in the window's room, so it shows even when that room
            // does not follow the machine's session (data-model.md 3.2).
            context.services.windows.newWorkspace(in: context.activeWindow?.state, on: daemon)
        })

        registry.bind("palette.moveWorkspaceToTop", run: { try place(context, $0) { .top(anchor: $0.id) } })
        registry.bind("workspace.moveToBottom", run: { try place(context, $0) { .bottom(anchor: $0.id) } })
        registry.bind("workspace.moveToNewGroup", run: { invocation in
            let workspace = try context.workspace(invocation).model
            try sidebar(showing: workspace, context).handle(.createGroup(.make(), name: invocation["name"]?.stringValue ?? "", color: .grey,
                                                                         workspaces: [SidebarWorkspaceID(workspace.id)]))
        })
        registry.bind("workspace.closeOthersInGroup", run: { invocation in
            let workspace = try context.workspace(invocation).model
            guard let group = try group(of: workspace, context) else { throw ActionFailure.invalidTarget(RefusalStrings.workspaceNotInGroup) }
            close(group.workspaces.map(\.id.rawValue).filter { $0 != workspace.id }, context)
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
            let id = ActionID(rawValue: "workspace.sortBy" + key.rawValue.prefix(1).uppercased() + key.rawValue.dropFirst())
            registry.bind(id, run: { _ in try sort(by: key, context) })
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
    private static func create(_ context: AppActionContext, _ invocation: ActionInvocation, anchorFree slot: WorkspaceSlot?,
                               then: (@MainActor @Sendable (String, SidebarBridge) -> Void)? = nil) throws {
        try spawn(context, anchor: try? context.workspace(invocation).model, cwd: nil, slot: slot, newTabPage: invocation.origin == .user,
                  then: then)
    }

    private static func spawn(_ context: AppActionContext, anchor: WorkspaceModel?, cwd: String?, slot: WorkspaceSlot?,
                              newTabPage: Bool, then: (@MainActor @Sendable (String, SidebarBridge) -> Void)? = nil) throws {
        let windows = context.services.windows
        let window = anchor.flatMap { windows.registry.value.owner(of: $0.id) } ?? context.activeWindow?.state.id
        let target = windows.targetWindow(preferring: window)
        var spawn = WorkspaceSpawn(cwd: cwd)
        spawn.slot = slot
        spawn.onListed = then
        // `then` places it itself (New Workspace in New Group): no second write.
        spawn.placesBySetting = then == nil
        spawn.opensNewTabPage = newTabPage
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

    // MARK: Place

    /// Moves the target workspace to `slot` in its window's sidebar, with
    /// the sidebar's optimistic update.
    private static func place(_ context: AppActionContext, _ invocation: ActionInvocation, _ slot: (WorkspaceModel) -> WorkspaceSlot) throws {
        let workspace = try context.workspace(invocation).model
        let bridge = try sidebar(showing: workspace, context)
        guard let machine = context.services.machines.daemon(forWorkspace: workspace.id)?.machineID,
              let position = slot(workspace).position(moving: [workspace.id], section: .machine(MachineID(machine)), in: bridge.model.sections)
        else { throw ActionFailure.invalidTarget(RefusalStrings.workspaceNotInSidebar) }
        bridge.handle(.reorder([SidebarWorkspaceID(workspace.id)], to: position))
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

    static func close(_ ids: [String], _ context: AppActionContext) {
        for id in ids {
            guard let (workspace, daemon) = context.services.machines.workspace(id: id), let key = workspace.key else { continue }
            let terminals = WorkspaceClose.closing(workspace, on: daemon)
            daemon.send("close-workspace") { try await WorkspaceClose.close(key, terminals: terminals, on: $0) }
        }
    }

    private static func select(_ context: AppActionContext, _ pick: ([SidebarWorkspaceID]) -> SidebarWorkspaceID?) throws {
        guard let window = context.activeWindow else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
        guard let id = pick(window.sidebar.model.selectableWorkspaces.map(\.id)) else { throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn) }
        context.services.windows.show(workspaceID: id.rawValue, in: window.state)
    }

    /// Sorts every container (the loose rows, each group) of the active
    /// window's sidebar; groups keep their place and members.
    private static func sort(by key: WorkspaceSortKey, _ context: AppActionContext) throws {
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
            var containers: [(GroupID?, [String])] = [(nil, section.nodes.compactMap { node in
                if case let .workspace(workspace) = node { return workspace.id.rawValue }
                return nil
            })]
            for case let .group(group) in section.nodes { containers.append((group.id, group.workspaces.map(\.id.rawValue))) }
            for (group, ids) in containers where ids.count > 1 {
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
