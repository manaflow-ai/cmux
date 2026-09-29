import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign

/// Binds catalog actions to handlers. Menus, shortcuts, the palette, and
/// context menus all resolve through the registry (REWRITE.md "Action
/// contract"), so each behavior is written once here.
enum AppActions {
    static func bind(_ services: AppServices) {
        bindApp(services)
        bindTabs(services)
        bindWorkspaces(services)
        bindLayout(services)
        bindTabGroups(services)
        bindBrowser(services)
        let registry = services.registry
        let context = AppActionContext(services: services)
        WindowHandlers.bind(into: registry, context: context)
        WorkspaceHandlers.bind(into: registry, context: context)
        WorkspaceMetadataHandlers.bind(into: registry, context: context)
        WorkspaceGroupHandlers.bind(into: registry, context: context)
        SidebarHandlers.bind(into: registry, context: context)
        SavedGroupHandlers.bind(into: registry, context: context)
        SettingsHandlers.bind(into: registry, context: context)
        AppearanceHandlers.bind(into: registry, context: context)
        BrowserHandlers.bind(into: registry, context: context)
        OpenInHandlers.bind(into: registry, context: context)
        NotificationHandlers.bind(into: registry, context: context)
        AgentHandlers.bind(into: registry, context: context)
        CloudHandlers.bind(into: registry, context: context)
    }

    static func scope(_ services: AppServices, _ invocation: ActionInvocation = ActionInvocation()) -> ActionScope {
        ActionScope(services: services, invocation: invocation)
    }

    private static func bindApp(_ services: AppServices) {
        let registry = services.registry
        // Terminate from a run-loop callout, not from inside the caller's
        // main-queue job (control socket, palette): terminateLater spins a
        // nested run loop, and the save Task could never get the main queue.
        registry.bind("quit") { RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) } }
        registry.bind("newWindow") { services.windows.newWindow() }
        registry.bind("closeWindow", isEnabled: { services.windows.active != nil }) {
            services.windows.active?.window?.performClose(nil)
        }
        registry.bind("toggleFullScreen") { services.windows.active?.window?.toggleFullScreen(nil) }
        registry.bind("toggleSidebar") { services.windows.active?.sidebar.model.toggleHidden() }
    }

    private static func bindTabs(_ services: AppServices) {
        let registry = services.registry
        registry.bind("newSurface", invoke: { scope(services, $0).pane?.newTerminalTab() })
        registry.bind("openBrowser", invoke: { scope(services, $0).pane?.newBrowserTab() })
        registry.bind("closeTab", invoke: { invocation in
            guard let (pane, id) = scope(services, invocation).tab else { return }
            pane.close([id])
        })
        registry.bind("nextSurface") { scope(services).pane?.selectAdjacent(1) }
        registry.bind("prevSurface") { scope(services).pane?.selectAdjacent(-1) }
        registry.bind("selectSurfaceByNumber", invoke: { invocation in
            guard let pane = scope(services, invocation).pane, let number = invocation["index"]?.intValue else { return }
            let ids = pane.orderedIDs
            guard !ids.isEmpty else { return }
            // Chrome: 9 always selects the last tab.
            pane.select(number >= 9 ? ids[ids.count - 1] : ids[min(number - 1, ids.count - 1)])
        })
        registry.bind("renameTab", invoke: { invocation in
            guard let (pane, id) = scope(services, invocation).tab else { return }
            if let name = invocation["name"]?.stringValue, !name.isEmpty, let tab = pane.tab(id) {
                let surface = tab.surface
                services.daemon.send("rename-surface") { try await $0.renameTab(surface, to: name) }
            } else {
                pane.rename(id)
            }
        })
        registry.bind("duplicateTab", invoke: { invocation in
            guard let (pane, id) = scope(services, invocation).tab else { return }
            pane.newTerminalTab(cwd: pane.tab(id)?.cwd)
        })
        registry.bind("closeOtherTabsInPane", invoke: { invocation in
            guard let (pane, id) = scope(services, invocation).tab else { return }
            pane.handle(.closeOthers(keeping: id))
        })
        registry.bind("closeTabsToRight", invoke: { invocation in
            guard let (pane, id) = scope(services, invocation).tab else { return }
            pane.handle(.closeToRight(of: id))
        })
        registry.bind("closeTabsToLeft", invoke: { invocation in
            guard let (pane, id) = scope(services, invocation).tab else { return }
            let ids = pane.orderedIDs
            guard let index = ids.firstIndex(of: id) else { return }
            pane.close(Array(ids[..<index]))
        })
        registry.bind("palette.toggleTabPin", invoke: { invocation in
            guard let (pane, id) = scope(services, invocation).tab else { return }
            pane.setPinned(id, pinned: !(pane.tab(id)?.pinned ?? false))
        })
        registry.bind("moveSurfaceLeft", invoke: { moveTab(services, $0, by: -1) })
        registry.bind("moveSurfaceRight", invoke: { moveTab(services, $0, by: 1) })
        registry.bind("palette.moveTabToNewWorkspace", invoke: { invocation in
            guard let (pane, id) = scope(services, invocation).tab, let tab = pane.tab(id) else { return }
            Task {
                guard let key = await TabMoves.toNewWorkspace(tab, services: services), let state = services.windows.active?.state else { return }
                services.windows.show(workspaceID: key.rawValue, in: state)
            }
        })
    }

    private static func moveTab(_ services: AppServices, _ invocation: ActionInvocation, by offset: Int) {
        guard let (pane, id) = scope(services, invocation).tab else { return }
        let ids = pane.orderedIDs
        guard let index = ids.firstIndex(of: id) else { return }
        let target = min(max(index + offset, 0), ids.count - 1)
        guard target != index else { return }
        pane.move(id, toPane: pane, index: target)
    }
}
