import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextSidebar

extension AppActions {
    static func bindWorkspaces(_ services: AppServices) {
        let registry = services.registry
        registry.bind("newTab", invoke: { newWorkspace(services, $0) })
        registry.bind("closeWorkspace", invoke: { invocation in
            guard let workspace = scope(services, invocation).workspace, let key = workspace.key else { return }
            let terminals = WorkspaceClose.terminals(of: workspace, on: services.activeDaemon)
            services.activeDaemon.send("close-workspace") { connection in
                try await WorkspaceClose.close(key, terminals: terminals, on: connection)
            }
        })
        registry.bind("renameWorkspace", invoke: { invocation in
            guard let workspace = scope(services, invocation).workspace, let key = workspace.key else { return }
            if let name = invocation["name"]?.stringValue, !name.isEmpty {
                services.activeDaemon.send("rename-workspace") { _ = try await $0.renameWorkspace(key, to: name) }
            } else {
                services.windows.active?.sidebar.container.sidebarView.beginRename(workspace: SidebarWorkspaceID(workspace.id))
            }
        })
        registry.bind("nextSidebarTab") { selectWorkspace(services, offset: 1) }
        registry.bind("prevSidebarTab") { selectWorkspace(services, offset: -1) }
        registry.bind("selectWorkspaceByNumber", invoke: { invocation in
            guard let number = invocation["index"]?.intValue, let state = services.windows.active?.state else { return }
            // Sidebar order across every machine section.
            let all = services.windows.active?.sidebar.model.allWorkspaces.map(\.id.rawValue) ?? []
            guard !all.isEmpty else { return }
            let pick = number >= 9 ? all[all.count - 1] : all[min(number - 1, all.count - 1)]
            services.windows.show(workspaceID: pick, in: state)
        })
        registry.bind("moveWorkspaceUp", invoke: { moveWorkspace(services, $0, by: -1) })
        registry.bind("moveWorkspaceDown", invoke: { moveWorkspace(services, $0, by: 1) })
    }

    /// New workspace with one terminal (`WorkspaceSpawn` arguments), shown
    /// in the active window unless `focus` is false (the CLI's default).
    private static func newWorkspace(_ services: AppServices, _ invocation: ActionInvocation) {
        let spawn = WorkspaceSpawn(invocation)
        let show = invocation["focus"]?.boolValue ?? true
        let state = services.windows.active?.state
        services.registry.track(Task {
            do {
                let id = try await services.windows.createWorkspace(spawn)
                guard show else { return nil }
                if let state { services.windows.show(workspaceID: id, in: state) } else { services.windows.open(record: nil, workspaceID: id) }
                return nil
            } catch {
                services.daemon.logger.error("create workspace failed: \(String(describing: error), privacy: .public)")
                return "new workspace: \(error)"
            }
        })
    }

    private static func selectWorkspace(_ services: AppServices, offset: Int) {
        guard let state = services.windows.active?.state else { return }
        let ids = services.windows.active?.sidebar.model.allWorkspaces.map(\.id.rawValue) ?? []
        guard !ids.isEmpty else { return }
        let current = state.workspaceID.flatMap(ids.firstIndex(of:)) ?? 0
        services.windows.show(workspaceID: ids[(current + offset + ids.count) % ids.count], in: state)
    }

    private static func moveWorkspace(_ services: AppServices, _ invocation: ActionInvocation, by offset: Int) {
        let store = services.activeDaemon.store
        guard let workspace = scope(services, invocation).workspace, let key = workspace.key,
              let index = store.workspaces.firstIndex(where: { $0 === workspace }) else { return }
        let target = min(max(index + offset, 0), store.workspaces.count - 1)
        guard target != index else { return }
        let daemon = services.activeDaemon
        Task {
            await daemon.perform("move-workspace", patch: .moveWorkspace(key: key, index: target)) { connection, _ in
                _ = try await connection.moveWorkspace(key, to: target)
            }
        }
    }
}
