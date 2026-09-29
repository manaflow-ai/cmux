import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextSidebar

extension AppActions {
    static func bindWorkspaces(_ services: AppServices) {
        let registry = services.registry
        registry.bind("newTab") { services.windows.newWorkspace(in: services.windows.active?.state) }
        registry.bind("closeWorkspace", invoke: { invocation in
            guard let key = scope(services, invocation).workspace?.key else { return }
            services.daemon.send("close-workspace") { _ = try await $0.closeWorkspace(key) }
        })
        registry.bind("renameWorkspace", invoke: { invocation in
            guard let workspace = scope(services, invocation).workspace, let key = workspace.key else { return }
            if let name = invocation["name"]?.stringValue, !name.isEmpty {
                services.daemon.send("rename-workspace") { _ = try await $0.renameWorkspace(key, to: name) }
            } else {
                services.windows.active?.sidebar.container.sidebarView.beginRename(workspace: SidebarWorkspaceID(workspace.id))
            }
        })
        registry.bind("nextSidebarTab") { selectWorkspace(services, offset: 1) }
        registry.bind("prevSidebarTab") { selectWorkspace(services, offset: -1) }
        registry.bind("selectWorkspaceByNumber", invoke: { invocation in
            guard let number = invocation["index"]?.intValue, let state = services.windows.active?.state else { return }
            let all = services.daemon.store.workspaces
            guard !all.isEmpty else { return }
            let pick = number >= 9 ? all[all.count - 1] : all[min(number - 1, all.count - 1)]
            services.windows.show(workspaceID: pick.id, in: state)
        })
        registry.bind("moveWorkspaceUp", invoke: { moveWorkspace(services, $0, by: -1) })
        registry.bind("moveWorkspaceDown", invoke: { moveWorkspace(services, $0, by: 1) })
    }

    private static func selectWorkspace(_ services: AppServices, offset: Int) {
        guard let state = services.windows.active?.state else { return }
        let ids = services.windows.active?.sidebar.model.allWorkspaces.map(\.id.rawValue) ?? []
        guard !ids.isEmpty else { return }
        let current = state.workspaceID.flatMap(ids.firstIndex(of:)) ?? 0
        services.windows.show(workspaceID: ids[(current + offset + ids.count) % ids.count], in: state)
    }

    private static func moveWorkspace(_ services: AppServices, _ invocation: ActionInvocation, by offset: Int) {
        let store = services.daemon.store
        guard let workspace = scope(services, invocation).workspace, let key = workspace.key,
              let index = store.workspaces.firstIndex(where: { $0 === workspace }) else { return }
        let target = min(max(index + offset, 0), store.workspaces.count - 1)
        guard target != index else { return }
        Task {
            await services.daemon.perform("move-workspace", patch: .moveWorkspace(key: key, index: target)) { connection, _ in
                _ = try await connection.moveWorkspace(key, to: target)
            }
        }
    }
}
