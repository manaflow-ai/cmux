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
        HistoryHandlers.bind(into: registry, context: context)
        TabSearchHandlers.bind(into: registry, context: context)
        PaletteScopeHandlers.bind(into: registry, context: context)
        BookmarkHandlers.bind(into: registry, context: context)
        AppStoreHandlers.bind(into: registry, context: context)
        WorkspaceHandlers.bind(into: registry, context: context)
        WorkspaceVerbHandlers.bind(into: registry, context: context)
        WorkspaceStructureHandlers.bind(into: registry, context: context)
        WorkspaceMetadataHandlers.bind(into: registry, context: context)
        WorkspaceGroupHandlers.bind(into: registry, context: context)
        RoomHandlers.bind(into: registry, context: context)
        ThemeHandlers.bind(into: registry, context: context)
        WindowMembershipHandlers.bind(into: registry, context: context)
        SidebarHandlers.bind(into: registry, context: context)
        SidebarSectionHandlers.bind(into: registry, context: context)
        SettingsHandlers.bind(into: registry, context: context)
        AppearanceHandlers.bind(into: registry, context: context)
        FocusRingHandlers.bind(into: registry, context: context)
        HibernationHandlers.bind(into: registry, context: context)
        TabHandlers.bind(into: registry, context: context)
        TabGroupHandlers.bind(into: registry, context: context)
        PaneHandlers.bind(into: registry, context: context)
        ColumnHandlers.bind(into: registry, context: context)
        StickyColumnHandlers.bind(into: registry, context: context)
        ScreenHandlers.bind(into: registry, context: context)
        TerminalHandlers.bind(into: registry, context: context)
        FindInDirectoryHandlers.bind(into: registry, context: context)
        GlobalSearchHandlers.bind(into: registry, context: context)
        BrowserHandlers.bind(into: registry, context: context)
        PageInfoHandlers.bind(into: registry, context: context)
        ExtensionHandlers.bind(into: registry, context: context)
        BrowserProfileHandlers.bind(into: registry, context: context)
        OpenInHandlers.bind(into: registry, context: context)
        NotificationHandlers.bind(into: registry, context: context)
        AgentHandlers.bind(into: registry, context: context)
        CloudHandlers.bind(into: registry, context: context)
        AccountsHandlers.bind(into: registry, context: context)
        RemoteHandlers.bind(into: registry, context: context)
        ResourceHandlers.bind(into: registry, context: context)
        context.observeRefusals()
        DestructiveConfirmation.install(services)
        ActionRouting.install(services)
    }

    static func scope(_ services: AppServices, _ invocation: ActionInvocation = ActionInvocation()) -> ActionScope {
        ActionScope(services: services, invocation: invocation)
    }

    private static func bindApp(_ services: AppServices) {
        let registry = services.registry
        // Quit and the local terminals (QuitCoordinator): a keyboard, menu
        // or Dock quit may ask; a scripted run (control socket, CLI) never
        // waits on the sheet and takes --keep-sessions / --end-sessions /
        // --end-everything.
        registry.bind("quit", invoke: { invocation in
            do {
                let origin = try QuitPolicy.origin(for: invocation, scripted: registry.isCapturingRefusal)
                services.quit.requestQuit(origin)
            } catch {
                registry.refuse(QuitArgumentConflict.reason)
            }
        })
        registry.bind("quitKeepSessions") { services.quit.requestQuit(.explicit(.keep)) }
        registry.bind("quitEndSessions") { services.quit.requestQuit(.explicit(.endKeepLayout)) }
        registry.bind("quitEndEverything") { services.quit.requestQuit(.explicit(.endEverything)) }
        registry.bind("newWindow") { services.windows.newWindow() }
        registry.bind("newIncognitoWindow") { services.windows.newIncognitoWindow() }
        registry.bind("closeWindow", isEnabled: { services.windows.active != nil }) {
            services.windows.active?.window?.performClose(nil)
        }
        registry.bind("toggleFullScreen") { services.windows.active?.window?.toggleFullScreen(nil) }
        registry.bind("toggleSidebar") { services.windows.active?.sidebar.model.toggle() }
    }
}
