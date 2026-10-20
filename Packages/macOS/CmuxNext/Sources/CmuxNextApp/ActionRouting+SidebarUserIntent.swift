import CmuxNextActions

extension ActionRouting {
    /// A run this app's user started (palette, menu, keyboard; never the CLI, MCP, a script, a
    /// page or another client) marks the active window's sidebar: the change it makes there may
    /// move rows on a spring. Changes nobody here asked for show in place (calm-sidebar-movement).
    static func installSidebarUserIntent(_ services: AppServices) {
        services.registry.willRunObservers.append { [weak services] _, origin in
            guard origin == .user else { return }
            services?.windows.active?.sidebar.model.noteUserIntent()
        }
    }
}
