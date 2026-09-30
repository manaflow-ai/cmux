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
        let registry = services.registry
        let context = AppActionContext(services: services)
        WindowHandlers.bind(into: registry, context: context)
        WorkspaceHandlers.bind(into: registry, context: context)
        WorkspaceMetadataHandlers.bind(into: registry, context: context)
        WorkspaceGroupHandlers.bind(into: registry, context: context)
        WindowMembershipHandlers.bind(into: registry, context: context)
        SidebarHandlers.bind(into: registry, context: context)
        SettingsHandlers.bind(into: registry, context: context)
        AppearanceHandlers.bind(into: registry, context: context)
        TabHandlers.bind(into: registry, context: context)
        TabGroupHandlers.bind(into: registry, context: context)
        PaneHandlers.bind(into: registry, context: context)
        ColumnHandlers.bind(into: registry, context: context)
        ScreenHandlers.bind(into: registry, context: context)
        TerminalHandlers.bind(into: registry, context: context)
        BrowserHandlers.bind(into: registry, context: context)
        PageInfoHandlers.bind(into: registry, context: context)
        ExtensionHandlers.bind(into: registry, context: context)
        OpenInHandlers.bind(into: registry, context: context)
        NotificationHandlers.bind(into: registry, context: context)
        AgentHandlers.bind(into: registry, context: context)
        CloudHandlers.bind(into: registry, context: context)
        context.observeRefusals()
        DestructiveConfirmation.install(services)
        ActionRouting.install(services)
    }

    static func scope(_ services: AppServices, _ invocation: ActionInvocation = ActionInvocation()) -> ActionScope {
        ActionScope(services: services, invocation: invocation)
    }

    private static func bindApp(_ services: AppServices) {
        let registry = services.registry
        // Terminate from a run-loop callout, not from inside the caller's
        // main-queue job (control socket, palette): terminateLater spins a
        // nested run loop, and the save Task could never get the main queue.
        registry.bind("quit") {
            RunLoop.main.perform(inModes: [.common]) {
                SheetDismissal.endAll()
                NSApp.terminate(nil)
            }
        }
        registry.bind("newWindow") { services.windows.newWindow() }
        registry.bind("closeWindow", isEnabled: { services.windows.active != nil }) {
            services.windows.active?.window?.performClose(nil)
        }
        registry.bind("toggleFullScreen") { services.windows.active?.window?.toggleFullScreen(nil) }
        registry.bind("toggleSidebar") { services.windows.active?.sidebar.model.toggle() }
    }
}
