import CmuxNextActions

extension ActionRouting {
    /// A run this app's user started (palette, menu, keyboard; never the CLI, MCP, a script, a
    /// page or another client) marks the active window's sidebar: the change it makes there may
    /// move rows on a spring. Changes nobody here asked for show in place (calm-sidebar-movement).
    /// A top-level one (a nested run answers no new press) is also the person's next intent: their new terminal's
    /// keyboard claim in the active window ends (`CreationInputCoordinator.personActed`).
    static func installUserIntentObservers(_ services: AppServices) {
        services.registry.willRunObservers.append { [weak services] _, origin in
            guard origin == .user, let services else { return }
            services.windows.active?.sidebar.model.noteUserIntent()
            guard ActionRunScope.current == nil else { return }
            services.keyRouter.creationInputCoordinator.personActed(in: services.windows.active?.window, event: services.registry.dispatchingInputEvent())
        }
    }
}
