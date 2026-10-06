import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHome
import CmuxNextLayout
import CmuxNextSidebar

extension AppActions {
    static func bindWorkspaces(_ services: AppServices) {
        let registry = services.registry
        registry.bind("newTab", invoke: { newWorkspace(services, $0) })
        registry.bind("closeWorkspace", invoke: { invocation in
            guard let workspace = scope(services, invocation).workspace, let key = workspace.key else { return }
            let terminals = WorkspaceClose.closing(workspace, on: services.activeDaemon)
            services.activeDaemon.send("close-workspace") { connection in
                try await WorkspaceClose.close(key, terminals: terminals, on: connection)
            }
        })
        registry.bind("renameWorkspace", invoke: { invocation in
            guard let workspace = scope(services, invocation).workspace, let key = workspace.key else { return }
            if let name = invocation["name"]?.stringValue, !name.isEmpty {
                services.activeDaemon.send("rename-workspace") { _ = try await $0.renameWorkspace(key, to: name) }
            } else {
                services.windows.active?.sidebar.container.beginRename(workspace: SidebarWorkspaceID(workspace.id))
            }
        })
        // Next / previous item in the current sidebar section; in the workspaces list, the workspaces (R119).
        registry.bind("nextSidebarTab") { stepSidebar(services, offset: 1) }
        registry.bind("prevSidebarTab") { stepSidebar(services, offset: -1) }
        registry.bind("selectWorkspaceByNumber", invoke: { invocation in
            guard let number = invocation["index"]?.intValue, let state = services.windows.active?.state else { return }
            // The first top item (Home by default) is 1, then the visible rows
            // top to bottom across every machine section (R119).
            guard let sidebar = services.windows.active?.sidebar else { return }
            let first = sidebar.model.layout.firstTopItem(room: sidebar.model.activeProfileID?.rawValue)?.id
            switch SidebarNumbering(firstTopItem: first, workspaces: sidebar.model.visibleWorkspaceIDs).pick(number) {
            case .topItem(let item)?: sidebar.activateLayoutItem(item)
            case .workspace(let id)?: services.windows.show(workspaceID: id, in: state)
            case nil: break
            }
        })
        // Home is a top page (TOP-SECTION-ITEMS-ARE-PAGES): the active
        // window shows it, from any origin (a focus action). With no window,
        // the store's home workspace opens one; else refused with why.
        registry.bind("home.show") {
            if TopPages.show(.home, services: services) != nil { return }
            guard services.windows.active == nil, let home = services.home.homeWorkspace else {
                services.registry.refuse(RefusalStrings.homeNotReady)
                return
            }
            services.windows.reveal(workspaceID: home.id)
        }
        // The composer's attach button as an action (home.attachFiles): a path
        // goes to the shown Home composer through its own intake (as a drop);
        // without one the shown composer opens its file picker.
        registry.bind("home.attachFiles", invoke: { invocation in
            guard let view = HomeNativeTranscriptView.shown(in: services.windows.active?.window), view.canAttach else {
                services.registry.refuse(RefusalStrings.homeAttachNoHome)
                return
            }
            guard let path = invocation["path"]?.stringValue, !path.isEmpty else {
                view.pickFiles()
                return
            }
            if view.attachFiles(paths: [path], via: .drop) == .missingFile {
                services.registry.refuse(RefusalStrings.homeAttachNoFile(path))
            }
        })
        // Debug > Save Last 10 Seconds (DEV and NIGHTLY): MessagesLab's flight recorder dump.
        registry.bind("home.saveFlightRecording") {
            if HomeFlightRecording.saveLastSeconds() == nil { services.registry.refuse(RefusalStrings.homeFlightRecorderOff) }
        }
                registry.bind("moveWorkspaceUp", invoke: { moveWorkspace(services, $0, by: -1) })
        registry.bind("moveWorkspaceDown", invoke: { moveWorkspace(services, $0, by: 1) })
    }

    /// New workspace (`WorkspaceSpawn` arguments: the New Tab page for a
    /// person, one terminal for a script or a `command`), shown
    /// in the active window unless `focus` is false (the CLI's default).
    /// With `activate: true` as well (`cmux open <dir>` run by a person) it
    /// also brings that window forward and activates the app
    /// (`NewWorkspaceFocus`).
    private static func newWorkspace(_ services: AppServices, _ invocation: ActionInvocation) {
        let spawn = WorkspaceSpawn(invocation)
        let focus = NewWorkspaceFocus(invocation)
        let show = focus.shows

        let windows = services.windows!
        // Shown: the active window, or a new one when none is open. Not
        // shown (the CLI default): the most recent window lists it, or a new
        // window when none is open (a workspace never lives in no window).
        let hasOpenWindow = !windows.registry.value.openWindows.isEmpty
        let target: String? = show || !hasOpenWindow ? windows.targetWindow(preferring: windows.active?.state.id) : nil
        // `machine` (App machine id; the CLI's `--session`): born on that
        // session's daemon (plans/cmux-next/data-model.md 1.3).
        let daemon = (invocation["machine"]?.targetValue?.id ?? invocation["machine"]?.stringValue).flatMap(services.machines.daemon(machine:))
        if invocation["machine"] != nil, daemon?.connection == nil {
            services.registry.track(Task { ActionWorkFailure(WorkspaceVerbStrings.machineNotConnected) })
            return
        }
        services.registry.track(Task {
            do {
                _ = try await windows.createWorkspace(spawn, on: daemon, into: target)
                if focus.activatesApp, let target { focusWindow(windows, target) }
                return nil
            } catch {
                services.daemon.logger.error("create workspace failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("new workspace", error)
            }
        })
    }

    /// Makes window `id` key and activates the app. A new window still
    /// waiting for its first workspace comes to the front when that shows.
    private static func focusWindow(_ windows: WindowManager, _ id: String) {
        guard windows.ordersWindowsIn, let controller = windows.controller(for: id) else { return }
        if windows.awaitingContent[id] != nil {
            windows.bringToFront(controller)
            WindowActivation.activateApp()
            return
        }
        guard let window = controller.window else { return }
        WindowActivation.show(window, .focus)
        windows.didActivate(controller)
    }

    private static func stepSidebar(_ services: AppServices, offset: Int) {
        let window = services.windows.active
        let shownPage = window?.focus.state.resolved.tab.flatMap(services.pages.page(ofTab:))
        if let sidebar = window?.sidebar,
           SidebarItemStepper.step(sidebar, by: offset, shownWorkspace: { window?.state.workspaceID }, shownPage: shownPage) { return }
        selectWorkspace(services, offset: offset)
    }

    private static func selectWorkspace(_ services: AppServices, offset: Int) {
        guard let state = services.windows.active?.state else { return }
        let ids = services.windows.active?.sidebar.model.selectableWorkspaces.map(\.id.rawValue) ?? []
        guard !ids.isEmpty else { return }
        let current = state.workspaceID.flatMap(ids.firstIndex(of:)) ?? 0
        services.windows.show(workspaceID: ids[(current + offset + ids.count) % ids.count], in: state)
    }

    private static func moveWorkspace(_ services: AppServices, _ invocation: ActionInvocation, by offset: Int) {
        if services.machines.local.store.personal.isLoaded { return movePersonalWorkspace(services, invocation, by: offset) }
        let store = services.activeDaemon.store
        guard let workspace = scope(services, invocation).workspace, let key = workspace.key,
              let index = store.workspaces.firstIndex(where: { $0 === workspace }) else { return }
        // Up/down among the workspaces its window lists: the daemon index of
        // the neighbor in that window (other windows' workspaces are skipped).
        let members = Set(services.windows.registry.value.owner(of: workspace.id).map(services.windows.registry.members(of:)) ?? [])
        let visible = store.workspaces.filter { members.isEmpty || members.contains($0.id) }
        guard let position = visible.firstIndex(where: { $0 === workspace }), visible.indices.contains(position + offset),
              let target = store.workspaces.firstIndex(where: { $0 === visible[position + offset] }), target != index else { return }
        let daemon = services.activeDaemon
        Task {
            await daemon.intend("move-workspace", .moveWorkspace(key: key, index: target)) { connection in
                _ = try await connection.moveWorkspace(key, to: target)
            }
        }
    }
}
