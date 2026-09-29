import AppKit
import CmuxNextActions
import CmuxNextDaemon

/// Workspace lifecycle, navigation, order, and bulk close (category
/// `workspace`). Names, colors, and notifications are in
/// `WorkspaceMetadataHandlers`; groups in `WorkspaceGroupHandlers`. Every
/// mutation is a daemon command; order changes carry an optimistic patch.
enum WorkspaceHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("openFolder", run: { _ in openFolder(context) })
        registry.bind("newBrowserWorkspace", requires: DaemonCapabilities.frontendBrowserTabs, daemon: context.services.activeDaemon, run: { _ in try newBrowserWorkspace(context) })
        registry.bind("nextSidebarTabInGroup", run: { invocation in try selectInGroup(context, invocation, offset: 1) })
        registry.bind("prevSidebarTabInGroup", run: { invocation in try selectInGroup(context, invocation, offset: -1) })
        registry.bind("palette.moveWorkspaceToTop", run: { invocation in
            let key = try context.workspace(invocation).key
            Task {
                await context.services.activeDaemon.perform("move-workspace", patch: .moveWorkspace(key: key, index: 0)) { connection, _ in
                    _ = try await connection.moveWorkspace(key, to: 0)
                }
            }
        })
        registry.bind("moveWorkspaceToWindow", run: { invocation in
            let workspace = try context.workspace(invocation).model
            let target = try context.window(invocation)
            context.services.windows.show(workspaceID: workspace.id, in: target.state)
            target.window?.orderFront(nil)
        })
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
        for id: ActionID in ["reopenPreviousSession", "reopenClosedWorkspace"] {
            registry.bindUnavailable([id], ActionFailure.needsDaemonCapability("closed-history-v1"))
        }
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
    static func createAndShow(_ context: AppActionContext, name: String? = nil, cwd: String? = nil,
                              then configure: (@Sendable (DaemonConnection, CreateTerminalResult) async throws -> Void)? = nil) {
        let services = context.services
        Task {
            guard let connection = services.activeDaemon.connection else { return }
            let created: String
            do {
                let key = WorkspaceKey.generate()
                created = try await services.emptyWorkspaces.populating(key) {
                    let workspace = try await connection.createWorkspace(name: name, key: key)
                    let terminal = try await connection.createTerminal(in: workspace.key, cwd: cwd ?? NSHomeDirectory())
                    try await configure?(connection, terminal)
                    return workspace.key.rawValue
                }
            } catch {
                services.daemon.logger.error("create workspace failed: \(String(describing: error), privacy: .public)")
                return
            }
            if let state = services.windows.active?.state {
                services.windows.show(workspaceID: created, in: state)
            } else {
                services.windows.open(record: nil, workspaceID: created)
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
            createAndShow(context, name: url.lastPathComponent, cwd: url.path)
        }
        if let window = context.activeWindow?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    /// A workspace whose only tab is a blank browser tab.
    private static func newBrowserWorkspace(_ context: AppActionContext) throws {
        try context.require(DaemonCapabilities.frontendBrowserTabs)
        createAndShow(context) { connection, terminal in
            guard let pane = terminal.pane else { return }
            _ = try await connection.newFrontendBrowserTab(url: "about:blank", engine: .webkit, in: pane)
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
        for key in workspaces.compactMap(\.key) {
            context.services.activeDaemon.send("close-workspace") { _ = try await $0.closeWorkspace(key) }
        }
    }
}
