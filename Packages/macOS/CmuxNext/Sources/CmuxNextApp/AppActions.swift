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
        bindWorkspaces(services)
        bindBrowser(services)
        // Tab, tab group, pane, column, screen, and terminal handlers live in
        // Handlers/ and bind right after this (AppDelegate).
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
        registry.bind("appearance.density.compact") { DesignSettings.shared.density = .compact }
        registry.bind("appearance.density.comfortable") { DesignSettings.shared.density = .comfortable }
    }
}
