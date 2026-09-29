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

    static func bindLayout(_ services: AppServices) {
        let registry = services.registry
        func content() -> WorkspaceContentController? { services.windows.active?.content }
        func focus(_ pane: PaneController?) { if let pane { content()?.layoutModel.focus(pane.layoutPaneID) } }
        registry.bind("splitRight", invoke: { invocation in
            focus(scope(services, invocation).pane)
            content()?.layoutModel.splitFocusedPane(axis: .horizontal)
        })
        registry.bind("splitDown", invoke: { invocation in
            focus(scope(services, invocation).pane)
            content()?.layoutModel.splitFocusedPane(axis: .vertical)
        })
        registry.bind("newColumn", invoke: { invocation in
            focus(scope(services, invocation).pane)
            content()?.layoutModel.newColumn()
        })
        for (id, direction) in [("focusLeft", LayoutDirection.left), ("focusRight", .right), ("focusUp", .up), ("focusDown", .down)] {
            registry.bind(ActionID(rawValue: id)) {
                guard let content = content(), let pane = content.layoutView.moveFocus(direction) else { return }
                content.panes[pane]?.focusContent()
            }
        }
        registry.bind("toggleSplitZoom", invoke: { invocation in
            guard let handle = scope(services, invocation).pane?.pane.handle else { return }
            services.daemon.send("zoom-pane") { _ = try await $0.zoomPane(handle) }
        })
        registry.bind("equalizeSplits") {
            guard let model = content()?.layoutModel, let screen = model.activeScreen else { return }
            let trees: [SplitNode] = switch screen.layout {
            case .splits(let root): [root]
            case .columns(let columns): columns.map(\.root)
            }
            for split in trees.flatMap(\.splits) { model.equalizeSplit(split) }
        }
    }
}
