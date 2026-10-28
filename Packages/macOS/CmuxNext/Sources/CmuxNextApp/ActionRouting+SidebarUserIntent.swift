import CmuxNextActions
import CmuxNextDesign

extension ActionRouting {
    /// A run this app's user started (palette, menu, keyboard; never the CLI, MCP, a script, a
    /// page or another client) marks the active window's sidebar: the change it makes there may
    /// move rows on a spring. Changes nobody here asked for show in place (calm-sidebar-movement).
    static func installSidebarUserIntent(_ services: AppServices) {
        services.registry.willRunObservers.append { [weak services] _, origin in
            guard origin == .user else { return }
            services?.windows.active?.sidebar.model.noteUserIntent()
        }
        // The Motion Inspector's one-intent check: each outermost run while it inspects (one nil check otherwise).
        services.registry.willRunObservers.append { [weak services] id, origin in
            guard let services, ActionRunScope.current == nil,
                  let inspector = DesignSettings.shared.activeMotionInspector as? MotionInspector else { return }
            let input = origin == .user ? ActionRegistry.inputTimestamp(of: services.registry.dispatchingInputEvent()) : nil
            inspector.noteActionStarted(id.rawValue, inputTimestamp: input)
        }
    }
}
