import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextPalette

/// Feeds the palette's workspace and tab pages from the daemon store.
enum PaletteSourcesBridge {
    static func make(services: AppServices) -> PaletteSources {
        PaletteSources(workspaces: WorkspaceSource(services: services), tabs: TabSource(services: services))
    }

    final class WorkspaceSource: PaletteWorkspaceSource {
        private unowned let services: AppServices
        init(services: AppServices) { self.services = services }

        var workspaces: [PaletteWorkspace] {
            let shown = services.windows.active?.state.workspaceID
            return services.daemon.store.workspaces.map { workspace in
                let cwd = workspace.screens.flatMap(\.panes).flatMap(\.tabs).first { $0.cwd != nil }?.cwd
                return PaletteWorkspace(id: workspace.id, title: workspace.displayName, directory: cwd,
                                        isSelected: workspace.id == shown, unreadCount: workspace.unreadCount)
            }
        }

        func selectWorkspace(id: String) {
            guard let state = services.windows.active?.state else { return }
            services.windows.show(workspaceID: id, in: state)
        }

        func renameWorkspace(id: String, to title: String) {
            guard let key = services.workspace(id: id)?.key else { return }
            services.daemon.send("rename-workspace") { connection in _ = try await connection.renameWorkspace(key, to: title) }
        }

        func closeWorkspace(id: String) {
            guard let key = services.workspace(id: id)?.key else { return }
            services.daemon.send("close-workspace") { connection in _ = try await connection.closeWorkspace(key) }
        }
    }

    final class TabSource: PaletteTabSource {
        private unowned let services: AppServices
        init(services: AppServices) { self.services = services }

        var tabs: [PaletteTab] {
            let selected = services.windows.active?.focusedPane?.selectedTab?.id
            return services.daemon.store.workspaces.flatMap { workspace in
                workspace.screens.flatMap(\.panes).flatMap(\.tabs).map { tab in
                    PaletteTab(id: tab.id, title: tab.displayTitle.isEmpty ? Strings.untitledTerminal : tab.displayTitle,
                               workspaceTitle: workspace.displayName, kind: tab.kind == .browser ? .browser : .terminal,
                               isSelected: tab.id == selected)
                }
            }
        }

        func selectTab(id: String) {
            guard let (_, pane) = services.locateTab(id),
                  let workspace = services.daemon.store.workspaces.first(where: { $0.screens.contains { $0.panes.contains { $0 === pane } } }),
                  let window = services.windows.active else { return }
            window.state.selection.select(id, in: pane.id)
            services.windows.show(workspaceID: workspace.id, in: window.state)
            services.paneController(for: pane)?.select(StripTabID(id))
        }

        func renameTab(id: String, to title: String) {
            guard let (tab, _) = services.locateTab(id) else { return }
            let surface = tab.surface
            services.daemon.send("rename-surface") { connection in try await connection.renameTab(surface, to: title) }
        }

        func closeTab(id: String) {
            guard let (_, pane) = services.locateTab(id), let controller = services.paneController(for: pane) else { return }
            controller.close([StripTabID(id)])
        }
    }
}
