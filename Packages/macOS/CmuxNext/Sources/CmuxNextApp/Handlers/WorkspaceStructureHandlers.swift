import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// Workspace verbs that change what a workspace holds: duplicate (layout and
/// directories, new terminals), merge into another workspace, move a pane
/// out into a new workspace, icon, copy path (REWRITE.md round 3).
enum WorkspaceStructureHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("workspace.duplicate", run: { try duplicate(context, $0, browsers: true) })
        registry.bind("workspace.duplicateTerminalsOnly", run: { try duplicate(context, $0, browsers: false) })
        registry.bind("workspace.copyPath", run: { invocation in
            let workspace = try context.workspace(invocation).model
            guard let cwd = WorkspaceVerbHandlers.directory(of: workspace, context) else {
                throw ActionFailure.invalidTarget(WorkspaceVerbStrings.noDirectory)
            }
            context.copy(cwd)
        })
        registry.bind("workspace.setIcon", run: { invocation in
            guard let icon = invocation["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces), WorkspaceIconValue.isValid(icon) else {
                throw ActionFailure.invalidTarget(WorkspaceVerbStrings.invalidIcon)
            }
            try setIcon(.set(icon), invocation, context)
        })
        registry.bind("workspace.clearIcon", run: { try setIcon(.clear, $0, context) })
        registry.bind("workspace.mergeInto", run: { try merge(context, $0) })
        registry.bind("pane.moveToNewWorkspace", run: { try movePane(context, $0) })
    }

    // MARK: Duplicate

    /// A new workspace below the target with the same name, color, icon,
    /// screens, columns, splits and tabs: new terminals in each terminal's
    /// directory and, with `browsers`, the same pages.
    private static func duplicate(_ context: AppActionContext, _ invocation: ActionInvocation, browsers: Bool) throws {
        let workspace = try context.workspace(invocation).model
        guard let daemon = context.services.machines.daemon(forWorkspace: workspace.id) else {
            throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
        }
        let withBrowsers = browsers && daemon.supports(DaemonCapabilities.shared.frontendBrowserTabs)
        var blueprint = WorkspaceBlueprint(workspace)
        if !withBrowsers { blueprint = blueprint.withoutBrowserTabs(fallbackDirectory: WorkspaceVerbHandlers.directory(of: workspace, context)) }
        let windows = context.services.windows!
        let target = windows.targetWindow(preferring: windows.registry.value.owner(of: workspace.id) ?? context.activeWindow?.state.id)
        var spawn = WorkspaceSpawn(cwd: firstLeafDirectory(blueprint), name: workspace.displayName)
        spawn.slot = .below(workspace.id)
        let engine: BrowserEngine = context.services.cache.browserTabs.map { tabs in
            if case .open(let choice) = tabs.resolve(requested: nil) { return choice.engine }
            return .webkit
        } ?? .webkit
        let metadata = daemon.supports(DaemonCapabilities.shared.workspaceMetadata)
        context.services.registry.track(Task {
            do {
                let id = try await windows.createWorkspace(spawn, on: daemon, into: target)
                guard let connection = daemon.connection else { return nil }
                let key = WorkspaceKey(rawValue: id)
                try await WorkspaceBlueprintBuilder(connection: connection, key: key, browsers: withBrowsers, defaultEngine: engine).build(blueprint)
                if metadata, blueprint.color != nil || blueprint.icon != nil {
                    try await connection.state.setWorkspaceIdentity(key, resource: daemon.store.stateResourceID(workspace: key),
                                                              color: blueprint.color.map { .set($0) } ?? .unchanged,
                                                              icon: blueprint.icon.map { .set($0) } ?? .unchanged)
                }
                return nil
            } catch {
                return ActionWorkFailure("duplicate workspace", error)
            }
        })
    }

    /// The directory the new workspace's first terminal starts in: the first
    /// pane's first tab when it is a terminal.
    private static func firstLeafDirectory(_ blueprint: WorkspaceBlueprint) -> String? {
        if case .terminal(let cwd)? = blueprint.screens.first?.columns.first?.root.tabs.first { return cwd }
        return blueprint.firstDirectory
    }

    // MARK: Icon

    private static func setIcon(_ update: FieldUpdate<String>, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let (workspace, key) = try context.workspace(invocation)
        guard let daemon = context.services.machines.daemon(forWorkspace: workspace.id) else {
            throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
        }
        guard daemon.supports(DaemonCapabilities.shared.workspaceMetadata) else {
            throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapabilities.shared.workspaceMetadata))
        }
        let resource = daemon.store.stateResourceID(workspace: key)
        daemon.send("set-workspace-metadata") { try await $0.state.setWorkspaceIdentity(key, resource: resource, icon: update) }
    }

    // MARK: Merge and pane moves

    /// Moves every tab of the target workspace into workspace `into` (after
    /// its tabs, in order); the emptied workspace then closes by the
    /// last-tab rule. Tabs never cross machines.
    private static func merge(_ context: AppActionContext, _ invocation: ActionInvocation) throws {
        let source = try context.workspace(invocation).model
        guard let ref = invocation["into"]?.targetValue, let into = context.services.workspace(id: ref.id) else {
            throw ActionFailure.invalidTarget(WorkspaceVerbStrings.mergeTargetRequired)
        }
        guard into !== source else { throw ActionFailure.invalidTarget(WorkspaceVerbStrings.mergeIntoItself) }
        let machines = context.services.machines
        guard machines.daemon(forWorkspace: source.id) === machines.daemon(forWorkspace: into.id) else {
            throw ActionFailure.invalidTarget(WorkspaceVerbStrings.otherMachine)
        }
        let tabs = source.screens.flatMap(\.panes).flatMap(\.tabs)
        moveTabs(tabs, into: into, context) { [services = context.services] in
            if let state = services.windows.active?.state { services.windows.show(workspaceID: into.id, in: state) }
        }
    }

    /// Moves the target pane's tabs into a new workspace (below its own):
    /// the first tab makes the workspace, the others follow in order.
    private static func movePane(_ context: AppActionContext, _ invocation: ActionInvocation) throws {
        guard let pane = context.daemonPane(invocation), let first = pane.tabs.first else {
            throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
        }
        let workspace = context.services.machines.allWorkspaces.map(\.0).first { $0.screens.contains { $0.panes.contains { $0 === pane } } }
        if let workspace, workspace.screens.flatMap(\.panes).count == 1 {
            throw ActionFailure.invalidTarget(WorkspaceVerbStrings.onlyPane)
        }
        let rest = Array(pane.tabs.dropFirst())
        let services = context.services
        // Read before the await: whether this run may change the view.
        let allowed = ActionRunScope.viewChangeAllowed()
        services.registry.track(Task {
            guard let key = await TabMoves.toNewWorkspace(first, services: services) else { return "move-tab-to-new-workspace failed (see the app log)" }
            guard let workspace, let state = services.windows.registry.value.owner(of: workspace.id).flatMap({ services.windows.states[$0] })
            else { return nil }
            // Once the daemon reports it: below the pane's workspace, the
            // other tabs follow in order, and the window shows it (the new
            // workspace is selected).
            services.windows.claim(workspaceID: key.rawValue, in: state, select: allowed)
            services.windows.place(newWorkspace: key.rawValue, in: state.id, at: .below(workspace.id)) { id, _ in
                if let created = services.workspace(id: id) { moveTabs(rest, into: created, context) {} }
                // A run this client's user did not start files it away.
                if allowed { services.windows.show(workspaceID: id, in: state) }
            }
            return nil
        })
    }

    /// Moves `tabs` into `workspace` one after another (each move waits for
    /// the previous one, so they keep their order).
    private static func moveTabs(_ tabs: [TabModel], into workspace: WorkspaceModel, _ context: AppActionContext, then: @escaping @MainActor () -> Void) {
        guard let tab = tabs.first else { return then() }
        TabMoves.toWorkspace(tab, workspace: workspace, services: context.services) { ok in
            guard ok else { return }
            moveTabs(Array(tabs.dropFirst()), into: workspace, context, then: then)
        }
    }
}

/// A workspace icon: an SF Symbol name or one emoji (the daemon's
/// `validate_presentation_icon`, data-model.md 9).
enum WorkspaceIconValue {
    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if WorkspaceIcon.isEmoji(value) { return true }
        return NSImage(systemSymbolName: value, accessibilityDescription: nil) != nil
    }
}
