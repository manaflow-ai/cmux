import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPages

/// Workspace lifecycle, navigation, order, and bulk close (category
/// `workspace`). Names, colors, and notifications are in
/// `WorkspaceMetadataHandlers`; groups in `WorkspaceGroupHandlers`. Every
/// mutation is a daemon command; order changes are store intents.
enum WorkspaceHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("openFolder", run: { _ in openFolder(context) })
        registry.bind("newBrowserWorkspace", requires: DaemonCapability.frontendBrowserTabs.rawValue, daemon: context.services.activeDaemon, run: { _ in try newBrowserWorkspace(context) })
        registry.bind("nextSidebarTabInGroup", run: { invocation in try selectInGroup(context, invocation, offset: 1) })
        registry.bind("prevSidebarTabInGroup", run: { invocation in try selectInGroup(context, invocation, offset: -1) })
        WorkspaceBulkClose.bind(into: registry, context: context)
        WorkspaceSetVerbs.bind(into: registry, context: context)

        VSCodeInlineHandlers.bind(into: registry, context: context)
        registry.bind("palette.openWorkspacePullRequests", run: { invocation in try openPullRequestLinks(context, invocation) })
        // Find Work: the palette's current-work page (workspaces needing attention, then the
        // user's GitHub review requests and assignments), from the palette, the CLI and the menu.
        context.services.palette.sources.actionPages["palette.findWork"] = { [weak services = context.services] in
            services.map { FindWorkPalettePage(services: $0).page() }
        }
        registry.bind("palette.findWork", run: { _ in
            context.services.palette.show(page: FindWorkPalettePage(services: context.services).page(),
                                          relativeTo: context.activeWindow?.window)
        })
        registry.bind("reopenPreviousSession", run: { _ in try PreviousLaunchRestorer(services: context.services).restore() })
        registry.bind("reopenClosedWorkspace", invoke: { _ in
            guard let entry = DaemonClosedHistory.entries([.workspace], in: context.services).first(where: { $0.item.group == nil })
                ?? context.refuse(RefusalStrings.noRecentlyClosedWorkspace) else { return }
            DaemonClosedHistory.reopen(entry, services: context.services)
        })
        LayoutTemplateHandlers.bind(into: registry, context: context)
    }

    /// Open All Workspace PR Links: each web link of the workspace's status
    /// entries as a browser tab in the focused pane of a window showing it,
    /// the first selected.
    private static func openPullRequestLinks(_ context: AppActionContext, _ invocation: ActionInvocation) throws {
        let (workspace, _) = try context.workspace(invocation)
        let links = WorkspacePullRequestLinks(workspace.status?.entries ?? []).urls
        guard !links.isEmpty else { throw ActionFailure(message: RefusalStrings.noWorkspacePullRequestLinks) }
        let shown = context.services.windows.controllers.compactMap(\.content).first { $0.workspace.id == workspace.id }
        guard let pane = shown?.focusedPane else { throw ActionFailure(message: RefusalStrings.noWindowShowsWorkspace) }
        for (index, url) in links.enumerated() { pane.newBrowserTab(url: url, background: index > 0) }
    }

    // MARK: Creation

    /// Creates a workspace (named `name`) with one terminal in `cwd` and
    /// shows it in the active window, or a new window when none is open.
    static func createAndShow(_ context: AppActionContext, name: String? = nil, cwd: String? = nil,
                              then configure: (@Sendable (DaemonConnection, CreateTerminalResult) async throws -> Void)? = nil) {
        createAndShow(services: context.services, name: name, cwd: cwd, then: configure)
    }

    /// Same; `newWindow` opens it in a new window (Shift-Return in the
    /// address bar) instead of the active one, `window` in that open
    /// window; `room` pins it to that space (Open Link in New Space), else
    /// it is born in its window's space. `daemon` holds it (default: the
    /// active window's machine). `configure` works on its first terminal.
    /// The one create path (`WorkspaceSpawner`): the window claims it in this
    /// turn and waits for it (#31658), and a failure releases the claim.
    static func createAndShow(services: AppServices, name: String? = nil, cwd: String? = nil,
                              newWindow: Bool = false, window: String? = nil, room: ProfileID? = nil, daemon chosen: DaemonService? = nil,
                              then configure: (@Sendable (DaemonConnection, CreateTerminalResult) async throws -> Void)? = nil) {
        let daemon = chosen ?? services.activeDaemon
        let windows = services.windows
        let target = windows.targetWindow(preferring: newWindow ? nil : window ?? windows.active?.state.id)
        var spawn = WorkspaceSpawn(cwd: cwd, name: name, profile: room)
        spawn.onFirstTerminal = configure
        let create = windows.startWorkspace(spawn, on: daemon, into: target)
        // One ticket for the whole creation, opened now: an action run
        // answers after it (and the barrier covers its echo), so `created`
        // names the workspace and the tabs `configure` made.
        let ticket = daemon.openTicket()
        Task {
            do {
                _ = try await create()
                await daemon.closeTicket(ticket, label: "create workspace", error: nil)
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
        try context.require(DaemonCapability.frontendBrowserTabs.rawValue)
        newBrowserWorkspace(services: context.services, url: nil)
    }

    /// Opens `url` in a cmux browser tab of a new workspace when links open in the cmux browser
    /// and the daemon serves browser tabs, else where the link rule sends it (Find Work's rows).
    static func openInNewWorkspace(_ url: URL, services: AppServices) {
        guard LinkRouter.shared.target(for: url) == .cmuxBrowser,
              services.activeDaemon.supports(DaemonCapability.frontendBrowserTabs.rawValue) else {
            LinkRouter.shared.open(url)
            return
        }
        LinkRouter.shared.record("workspace:" + url.absoluteString)
        newBrowserWorkspace(services: services, url: url.absoluteString)
    }

    /// A new workspace holding one browser tab at `url` (the new-tab page when nil).
    static func newBrowserWorkspace(services: AppServices, url: String?) {
        let browserTabs = services.cache.browserTabs
        guard case .open(let choice) = browserTabs.resolve(requested: nil) else { return }
        let fallbacks = browserTabs.fallbacks, machine = services.activeDaemon.machineID
        let address = url ?? services.newTabAddress(for: choice)
        createAndShow(services: services) { connection, terminal in
            guard let pane = terminal.pane else { return }
            // On the active machine's connection (it may be a Cloud machine).
            let created = try await connection.newFrontendBrowserTab(url: address, engine: choice.engine, in: pane)
            if let reason = choice.fallback {
                await fallbacks.record(reason, source: .newTab, machine: machine, surface: created.surface)
            }
            if let surface = terminal.surface { try await connection.closeTab(surface) }
        }
    }

    // MARK: Navigation

    /// Next or previous workspace among the members of the target's group, as the sidebar shows
    /// the group (the group Close Other Workspaces in Group reads). A navigation with nowhere to
    /// go (R136: no group, or alone in it) is refused quietly: callers get the reason.
    private static func selectInGroup(_ context: AppActionContext, _ invocation: ActionInvocation, offset: Int) throws {
        let current = try context.workspace(invocation).model
        guard let state = context.activeWindow?.state else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
        guard let group = try WorkspaceVerbHandlers.group(of: current, context) else {
            throw ActionFailure.noTarget(RefusalStrings.workspaceNotInGroup)
        }
        let peers = group.workspaces.map(\.id.rawValue)
        guard let index = peers.firstIndex(of: current.id), peers.count > 1 else {
            throw ActionFailure.noTarget(RefusalStrings.noOtherWorkspaceInGroup)
        }
        context.services.windows.show(workspaceID: peers[(index + offset + peers.count) % peers.count], in: state)
    }
}
