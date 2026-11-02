import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar

/// Workspace verbs that change what a workspace holds: duplicate (layout and
/// directories, new terminals), merge into another workspace, move a pane
/// out into a new workspace or window, icon, copy path (REWRITE.md round 3).
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
            // An icon argument (CLI, MCP, scripts) sets it; without one (palette, menu) the
            // picker opens and its pick takes the same path.
            if let icon = invocation["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
                guard WorkspaceIconValue.isValid(icon, assets: true) else {
                    throw ActionFailure.invalidTarget(WorkspaceVerbStrings.invalidIcon)
                }
                return try changeIcon(to: icon, invocation, context)
            }
            // The target is fixed now: a pick applies to it even if focus moves meanwhile.
            let workspace = try context.workspace(invocation).model
            guard let anchor = context.services.iconPicker.anchor(workspace: workspace.id) else {
                throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen)
            }
            let assets = IconAssetStore.owner(context.services.machines.daemon(forWorkspace: workspace.id))
            context.services.iconPicker.pick(current: workspace.icon, target: "workspace:\(workspace.id)", at: anchor,
                                             assets: assets) { result in
                switch result {
                case .set(let icon) where WorkspaceIconValue.isValid(icon, assets: true):
                    try? IconHistory.workspace(context).change(workspace.id, from: workspace.icon, to: icon, origin: .user)
                case .clear: try? IconHistory.workspace(context).change(workspace.id, from: workspace.icon, to: nil, origin: .user)
                case .set, .cancel: break
                }
            }
        })
        registry.bind("workspace.clearIcon", run: { try changeIcon(to: nil, $0, context) })
        registry.bind("workspace.mergeInto", run: { try merge(context, $0) })
        registry.bind("pane.moveToNewWorkspace", run: { try movePane(context, $0, newWindow: false) })
        registry.bind("pane.moveToNewWindow", run: { try movePane(context, $0, newWindow: true) })
    }

    // MARK: Duplicate

    /// A new workspace below the target with the same name, color, icon,
    /// screens, columns, splits and tabs: new terminals in each terminal's
    /// directory and, with `browsers`, the same pages.
    private static func duplicate(_ context: AppActionContext, _ invocation: ActionInvocation, browsers: Bool) throws {
        for workspace in try WindowMembershipHandlers.rowTargets(invocation, context) {
            try duplicate(context, workspace, browsers: browsers)
        }
    }

    /// `done` gets the new workspace's id once its layout is built (nil when it failed).
    static func duplicate(_ context: AppActionContext, _ workspace: WorkspaceModel, browsers: Bool,
                          done: (@MainActor @Sendable (String?) -> Void)? = nil) throws {
        guard let daemon = context.services.machines.daemon(forWorkspace: workspace.id) else {
            throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
        }
        var blueprint = WorkspaceBlueprint(workspace)
        if !browsers || !daemon.supports(DaemonCapability.frontendBrowserTabs.rawValue) {
            blueprint = blueprint.withoutBrowserTabs(fallbackDirectory: WorkspaceVerbHandlers.directory(of: workspace, context))
        }
        let windows = context.services.windows
        let target = windows.targetWindow(preferring: windows.registry.value.owner(of: workspace.id) ?? context.activeWindow?.state.id)
        build(blueprint, name: workspace.displayName, slot: .below(workspace.id), on: daemon, into: target,
              label: "duplicate workspace", services: context.services, done: done)
    }

    /// Creates a workspace named `name` in window `target` (at `slot`, nil: `workspaces.newPlacement`)
    /// and builds `blueprint` into it with new terminals, its color and icon too: the one path of
    /// Duplicate Workspace and New Workspace from Template. Browser tabs open only where the daemon
    /// serves them (else they are left out). `done` gets the new workspace's id once its layout is
    /// built (nil when it failed); the failure is the returned work's result. `tracks` false leaves
    /// the work untracked, for a caller that awaits it inside its own tracked work.
    @discardableResult
    static func build(_ blueprint: WorkspaceBlueprint, name: String?, slot: WorkspaceSlot?, on daemon: DaemonService, into target: String,
                      label: String, services: AppServices, tracks: Bool = true,
                      done: (@MainActor @Sendable (String?) -> Void)? = nil) -> ActionWork {
        let withBrowsers = daemon.supports(DaemonCapability.frontendBrowserTabs.rawValue)
        let blueprint = withBrowsers ? blueprint : blueprint.withoutBrowserTabs(fallbackDirectory: blueprint.firstDirectory)
        let windows = services.windows
        var spawn = WorkspaceSpawn(cwd: firstLeafDirectory(blueprint), name: name)
        spawn.slot = slot
        let engine: BrowserEngine = if case .open(let choice) = services.cache.browserTabs.resolve(requested: nil) {
            choice.engine
        } else {
            .webkit
        }
        let metadata = daemon.supports(DaemonCapability.workspaceMetadata.rawValue)
        let work = ActionWork { @MainActor in
            do {
                let id = try await windows.createWorkspace(spawn, on: daemon, into: target)
                let key = WorkspaceKey(rawValue: id)
                let resource = daemon.store.stateResourceID(workspace: key)
                // Through the funnel: the action run waits for the layout's
                // echo, so `created` names the tabs it made.
                try await daemon.perform(label + " layout") { connection in
                    try await WorkspaceBlueprintBuilder(connection: connection, key: key, browsers: withBrowsers, defaultEngine: engine)
                        .build(blueprint)
                    if metadata, blueprint.color != nil || blueprint.icon != nil {
                        try await connection.state.setWorkspaceIdentity(key, resource: resource,
                                                                  color: blueprint.color.map { .set($0) } ?? .unchanged,
                                                                  icon: blueprint.icon.map { .set($0) } ?? .unchanged)
                    }
                }
                done?(id)
                return nil
            } catch {
                done?(nil)
                return ActionWorkFailure(label, error)
            }
        }
        if tracks { services.registry.track(work) }
        return work
    }

    /// The directory the new workspace's first terminal starts in: the first
    /// pane's first tab when it is a terminal.
    private static func firstLeafDirectory(_ blueprint: WorkspaceBlueprint) -> String? {
        if case .terminal(let cwd, _)? = blueprint.screens.first?.columns.first?.root.tabs.first { return cwd }
        return blueprint.firstDirectory
    }

    // MARK: Icon

    /// Sets (nil removes) the target's icon; a user's change offers an undo toast.
    private static func changeIcon(to icon: String?, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let workspace = try context.workspace(invocation).model
        try IconHistory.workspace(context).change(workspace.id, from: workspace.icon, to: icon, origin: invocation.origin)
    }

    static func setIcon(_ update: FieldUpdate<String>, workspace: WorkspaceModel, key: WorkspaceKey,
                                _ context: AppActionContext) throws {
        guard let daemon = context.services.machines.daemon(forWorkspace: workspace.id) else {
            throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
        }
        guard daemon.supports(DaemonCapability.workspaceMetadata.rawValue) else {
            throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapability.workspaceMetadata.rawValue))
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
        // Home keeps its tabs and takes no workspace's, as a drag merge refuses it (cx-zjtn.4).
        guard !WorkspaceMerge.staysPut(kind: source.kind) else { throw ActionFailure.invalidTarget(RefusalStrings.homeKeepsItsTabs) }
        guard !WorkspaceMerge.staysPut(kind: into.kind) else { throw ActionFailure.invalidTarget(WorkspaceVerbStrings.mergeIntoHome) }
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
    /// Move Pane to New Workspace, or to New Window (beside its window, `openMovedWindow`): the
    /// daemon moves each tab, so terminals keep running and pages are reparented, not reloaded.
    private static func movePane(_ context: AppActionContext, _ invocation: ActionInvocation, newWindow: Bool) throws {
        guard let pane = context.daemonPane(invocation), let first = pane.tabs.first else {
            throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
        }
        let services = context.services, windows = services.windows
        if newWindow, let reason = TabPromotion.refusal(tab: first, services: services) { throw ActionFailure.invalidTarget(reason) }
        let workspace = services.machines.allWorkspaces.map(\.0).first { $0.screens.contains { $0.panes.contains { $0 === pane } } }
        // Read before the await: whether this run may change the view, and where the pane came from.
        let allowed = ActionRunScope.viewChangeAllowed(), origin = windows.moveOrigin(of: workspace?.id)
        if let workspace, workspace.screens.flatMap(\.panes).count == 1 {
            // The only pane: a new window takes its workspace; a new workspace would leave nothing.
            guard newWindow else { throw ActionFailure.invalidTarget(WorkspaceVerbStrings.onlyPane) }
            return windows.openMovedWindow([workspace.id], from: origin, select: allowed)
        }
        let rest = Array(pane.tabs.dropFirst())
        let work: ActionWork = Task {
            guard let key = await TabMoves.toNewWorkspace(first, services: services) else { return "move-tab-to-new-workspace failed (see the app log)" }
            if newWindow {
                await TabMoves.join(rest[...], workspace: key, services: services)
                windows.openMovedWindow([key.rawValue], from: origin, select: allowed)
                return nil
            }
            guard let workspace, let state = windows.registry.value.owner(of: workspace.id).flatMap({ windows.states[$0] }) else { return nil }
            // Once the daemon reports it: below the pane's workspace, the
            // other tabs follow in order, and the window shows it (the new
            // workspace is selected).
            windows.claim(workspaceID: key.rawValue, in: state, select: allowed)
            windows.place(newWorkspace: key.rawValue, in: state.id, at: .below(workspace.id)) { id, _ in
                if let created = services.workspace(id: id) { moveTabs(rest, into: created, context) {} }
                // A run this client's user did not start files it away.
                if allowed { windows.show(workspaceID: id, in: state) }
            }
            return nil
        }
        if !newWindow { services.registry.track(work) }
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

/// An icon the daemon stores: one emoji, or an SF Symbol name this Mac draws
/// (``IconValue``; the daemon's `validate_presentation_icon`). With `assets`
/// (fields that take `icon-assets-v1` values, such as the workspace icon) also
/// an image or SVG asset; the daemon refuses one it has not stored.
enum WorkspaceIconValue {
    static func isValid(_ value: String, assets: Bool = false) -> Bool {
        switch IconValue(wire: value) {
        case .emoji?: true
        case .symbol(let name)?: NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        case .image?, .svg?: assets
        case nil: false
        }
    }
}
