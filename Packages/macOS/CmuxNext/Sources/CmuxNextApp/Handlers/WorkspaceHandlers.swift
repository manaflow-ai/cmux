import AppKit
import CmuxNextActions
import CmuxNextDaemon

/// Workspace lifecycle, navigation, order, and bulk close (category
/// `workspace`). Names, colors, and notifications are in
/// `WorkspaceMetadataHandlers`; groups in `WorkspaceGroupHandlers`. Every
/// mutation is a daemon command; order changes are store intents.
enum WorkspaceHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("openFolder", run: { _ in openFolder(context) })
        registry.bind("newBrowserWorkspace", requires: DaemonCapabilities.shared.frontendBrowserTabs, daemon: context.services.activeDaemon, run: { _ in try newBrowserWorkspace(context) })
        registry.bind("nextSidebarTabInGroup", run: { invocation in try selectInGroup(context, invocation, offset: 1) })
        registry.bind("prevSidebarTabInGroup", run: { invocation in try selectInGroup(context, invocation, offset: -1) })
        registry.bind("palette.closeOtherWorkspaces", run: { invocation in
            let keep = try context.workspace(invocation).model
            close(context.sidebarOrder.filter { $0 !== keep }, context)
        })
        registry.bind("palette.closeWorkspacesBelow", run: { invocation in
            let (order, index) = try position(context, invocation)
            close(Array(order[(index + 1)...]), context)
        })
        registry.bind("palette.closeWorkspacesAbove", run: { invocation in
            let (order, index) = try position(context, invocation)
            close(Array(order[..<index]), context)
        })

        registry.bindUnavailable(["palette.openFolderInVSCodeInline"], ActionFailure.needsAppCapability("vscode-inline"))
        registry.bindUnavailable(["palette.openWorkspacePullRequests"], ActionFailure.needsAppCapability("github-integration"))
        registry.bindUnavailable(["palette.findWork"], ActionFailure.needsAppCapability("github-integration"))
        registry.bindUnavailable(["reopenPreviousSession"], ActionFailure.needsDaemonCapability("closed-history-v1"))
        registry.bind("reopenClosedWorkspace", invoke: { _ in
            guard let entry = DaemonClosedHistory.entries([.workspace], in: context.services).first(where: { $0.item.group == nil })
                ?? context.refuse(RefusalStrings.noRecentlyClosedWorkspace) else { return }
            DaemonClosedHistory.reopen(entry, services: context.services)
        })
        for id: ActionID in ["saveLayoutTemplate", "palette.layout.open", "manageLayouts"] {
            registry.bindUnavailable([id], ActionFailure.needsDaemonCapability("layout-templates-v1"))
        }
        for id: ActionID in ["reconnectWorkspace", "disconnectWorkspace", "copyWorkspaceSSHError"] {
            registry.bindUnavailable([id], ActionFailure.needsDaemonCapability("remote-workspaces-v1"))
        }
    }

    // MARK: Creation

    /// Creates a workspace (named `name`) with one terminal in `cwd` and
    /// shows it in the active window, or a new window when none is open.
    static func createAndShow(_ context: AppActionContext, name: String? = nil, cwd: String? = nil, key: WorkspaceKey? = nil,
                              then configure: (@Sendable (DaemonConnection, CreateTerminalResult) async throws -> Void)? = nil) {
        createAndShow(services: context.services, name: name, cwd: cwd, key: key, then: configure)
    }

    /// Same; `newWindow` opens it in a new window (Shift-Return in the
    /// address bar) instead of the active one, `window` in that open
    /// window; `room` pins it to that space first (Open Link in New Space).
    /// `key` names the new workspace (a History reopen picks it first); a fresh one by default.
    static func createAndShow(services: AppServices, name: String? = nil, cwd: String? = nil, key workspaceKey: WorkspaceKey? = nil,
                              newWindow: Bool = false, window: String? = nil, room: ProfileID? = nil,
                              then configure: (@Sendable (DaemonConnection, CreateTerminalResult) async throws -> Void)? = nil) {
        let daemon = services.activeDaemon
        let windows = services.windows
        // Claimed before the create command, so the workspace lands in (or
        // opens) its window in the step that first mirrors it.
        let target = windows.targetWindow(preferring: newWindow ? nil : window ?? windows.active?.state.id)
        let home = services.machines.local
        // One ticket for the whole creation, opened now: an action run
        // answers after it (and the barrier covers its echo), so `created`
        // names the workspace and the tabs `configure` made.
        let ticket = daemon.openTicket()
        Task {
            guard let connection = daemon.connection else {
                await daemon.closeTicket(ticket, label: "create workspace", error: DaemonError.notConnected)
                return
            }
            do {
                let key = workspaceKey ?? WorkspaceKey.generate()
                // A fresh workspace goes to the `workspaces.newPlacement` slot; a
                // History reopen (`workspaceKey`) keeps the place the daemon kept.
                if workspaceKey == nil {
                    NewWorkspacePlacements.expect(key.rawValue, in: target, byDefault: NewWorkspacePlacements.rule(for: target, in: windows), windows: windows)
                }
                windows.claimNew(workspaceID: key.rawValue, window: target)
                if let room, let session = daemon.store.registryID, let homeConnection = home.connection {
                    try await homeConnection.pinWorkspace(session: session, key: key, to: room)
                }
                _ = try await WorkspaceCreation.create(key, name: name, on: connection, repair: services.emptyWorkspaces) { created in
                    let terminal = try await connection.createTerminal(in: created, cwd: cwd ?? NSHomeDirectory())
                    try await configure?(connection, terminal)
                    return created.rawValue
                }
                await daemon.closeTicket(ticket, label: "create workspace", error: nil, replying: connection)
            } catch {
                services.daemon.logger.error("create workspace failed: \(String(describing: error), privacy: .public)")
                await daemon.closeTicket(ticket, label: "create workspace", error: error)
            }
        }
    }

    private static func openFolder(_ context: AppActionContext) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            createAndShow(context, name: WorkspaceSpawn.folderName(url.path), cwd: url.path)
        }
        if let window = context.activeWindow?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    /// A workspace whose only tab is a blank browser tab.
    private static func newBrowserWorkspace(_ context: AppActionContext) throws {
        try context.require(DaemonCapabilities.shared.frontendBrowserTabs)
        let browserTabs = context.services.cache.browserTabs
        guard case .open(let choice) = browserTabs.resolve(requested: nil) else { return }
        let fallbacks = browserTabs.fallbacks
        let address = context.services.newTabAddress(for: choice)
        createAndShow(context) { connection, terminal in
            guard let pane = terminal.pane else { return }
            // On the active machine's connection (it may be a Cloud machine).
            let created = try await connection.newFrontendBrowserTab(url: address, engine: choice.engine, in: pane)
            if let reason = choice.fallback {
                await fallbacks.record(reason, source: .newTab, surface: created.surface)
            }
            if let surface = terminal.surface { try await connection.closeTab(surface) }
        }
    }

    // MARK: Navigation

    private static func selectInGroup(_ context: AppActionContext, _ invocation: ActionInvocation, offset: Int) throws {
        let current = try context.workspace(invocation).model
        guard let state = context.activeWindow?.state else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
        let peers = context.sidebarOrder.filter { $0.group == current.group }
        guard let index = peers.firstIndex(where: { $0 === current }), peers.count > 1 else { return }
        context.services.windows.show(workspaceID: peers[(index + offset + peers.count) % peers.count].id, in: state)
    }

    // MARK: Close

    private static func position(_ context: AppActionContext, _ invocation: ActionInvocation) throws -> ([WorkspaceModel], Int) {
        let target = try context.workspace(invocation).model
        let order = context.sidebarOrder
        guard let index = order.firstIndex(where: { $0 === target }) else { throw ActionFailure.invalidTarget(RefusalStrings.workspaceNotInSidebar) }
        return (order, index)
    }

    static func close(_ workspaces: [WorkspaceModel], _ context: AppActionContext) {
        for workspace in workspaces {
            guard let key = workspace.key else { continue }
            let terminals = WorkspaceClose.closing(workspace, on: context.services.activeDaemon)
            context.services.activeDaemon.send("close-workspace") { try await WorkspaceClose.close(key, terminals: terminals, on: $0) }
        }
    }
}
