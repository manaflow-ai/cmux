import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebarActions
import CmuxNextWorkspaceNaming
import os

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
        // Pin/Unpin Chat on a history row: bound with the app's actions, with or without a local acpmux (the
        // Chats feed only fills the history; a launch without one used to leave the action unbound).
        SidebarChatHistoryFeed.bind(into: registry)
        FilesPaneHandlers.bind(into: registry, context: context)
        HistoryHandlers.bind(into: registry, context: context)
        StashHandlers.bind(into: registry, context: context)
        TabSearchHandlers.bind(into: registry, context: context)
        PaletteScopeHandlers.bind(into: registry, context: context)
        BookmarkHandlers.bind(into: registry, context: context)
        BookmarkIconHandlers.bind(into: registry, context: context)
        AppStoreHandlers.bind(into: registry, context: context)
        TasksHandlers.bind(into: registry, context: context)
        TaskManagerHandlers.bind(into: registry, context: context)
        KeybindingHandlers.bind(into: registry, context: context)
        PageCommandHandlers.bind(into: registry, context: context)
        ListHandlers.bind(into: registry, context: context)
        PasswordHandlers.bind(into: registry, context: context)
        CloudPageHandlers.bind(into: registry, context: context)
        ServerHandlers.bind(into: registry, context: context)
        WorkspaceHandlers.bind(into: registry, context: context)
        WorkspaceVerbHandlers.bind(into: registry, context: context)
        WorkspaceStructureHandlers.bind(into: registry, context: context)
        WorkspaceMetadataHandlers.bind(into: registry, context: context)
        WorkspaceActivityNameActions(host: services).bind(into: registry)
        WorkspaceNotesHandlers.bind(into: registry, context: context)
        WorkspaceChecklistHandlers.bind(into: registry, context: context)
        WorkspaceGroupHandlers.bind(into: registry, context: context)
        SidebarActionSet(host: services, autoArchive: services.autoArchive).bind(into: registry)
        NotificationSoundActions(host: services, gate: services.notifications.soundGate).bind(into: registry)
        RoomHandlers.bind(into: registry, context: context)
        RoomMenuHandlers.bind(into: registry, context: context)
        ThemeHandlers.bind(into: registry, context: context)
        RemoteLocalhostHandlers.bind(into: registry, context: context)
        WindowMembershipHandlers.bind(into: registry, context: context)
        SidebarHandlers.bind(into: registry, context: context)
        VaultHandlers.bind(into: registry, context: context)
        RightSidebarHandlers.bind(into: registry, context: context)
        SidebarSectionHandlers.bind(into: registry, context: context)
        SidebarHiddenSections.bind(into: registry, context: context)
        SidebarPriorityFeed.bind(into: registry, context: context)
        SidebarGroupByActions.bind(into: registry, context: context)
        SidebarMinimalToggle.bind(into: registry, context: context)
        MatchTerminalBackgroundToggle.bind(into: registry, context: context)
        SidebarDensityActions.bind(into: registry, context: context)
        SettingsHandlers.bind(into: registry, context: context)
        AppearanceHandlers.bind(into: registry, context: context)
        PaneBackgroundHandlers(context: context).bind(into: registry)
        DensityHandlers.bind(into: registry, context: context)
        FocusRingHandlers.bind(into: registry, context: context)
        HibernationHandlers.bind(into: registry, context: context)
        TabHandlers.bind(into: registry, context: context)
        TabIconHandlers.bind(into: registry, context: context)
        TabGroupHandlers.bind(into: registry, context: context)
        GroupIconHandlers.bind(into: registry, context: context)
        MachineIconHandlers.bind(into: registry, context: context)
        PaneHandlers.bind(into: registry, context: context)
        ColumnHandlers.bind(into: registry, context: context)
        CanvasHandlers.bind(into: registry, context: context)
        ColumnDocking.bind(into: registry, context: context)
        ColumnAvailability.bind(into: registry, context: context)
        ScreenHandlers.bind(into: registry, context: context)
        TerminalHandlers.bind(into: registry, context: context)
        FindInDirectoryHandlers.bind(into: registry, context: context)
        GlobalSearchHandlers.bind(into: registry, context: context)
        BrowserHandlers.bind(into: registry, context: context)
        ScreenshotHandlers.bind(into: registry, context: context)
        DevToolsHandlers.bind(into: registry, context: context)
        HintHandlers.bind(into: registry, context: context)
        MusicHandlers.bind(into: registry, context: context)
        VoiceRoomHandlers.bind(into: registry, context: context)
        ChiefScreenShareActions(share: context.services.chiefScreenShare, registry: registry).bind()
        NowPlayingCardHandlers.bind(into: registry, context: context)
        PictureInPictureHandlers.bind(into: registry, context: context)
        StatsPageTab.bind(into: registry, context: context)
        ChiefUsagePageTab.bind(into: registry, context: context)
        ChiefViewsPageTab.bind(into: registry, context: context)
        PhoneHandlers.bind(into: registry, context: context)
        MobilePairingPageService.bind(into: registry, context: context)
        BrowserHitHandlers.bind(into: registry, context: context)
        DiffHandlers.bind(into: registry, context: context)
        FilePageHandlers.bind(into: registry, context: context)
        AgentExtensionHandlers.bind(into: registry, context: context)
        ViewerHandlers.bind(into: registry, context: context)
        PageInfoHandlers.bind(into: registry, context: context)
        CertificateWarningHandlers.bind(into: registry, context: context)
        ExtensionHandlers.bind(into: registry, context: context)
        BrowserProfileHandlers.bind(into: registry, context: context)
        OpenInHandlers.bind(into: registry, context: context)
        NotificationHandlers.bind(into: registry, context: context)
        AgentHandlers.bind(into: registry, context: context)
        AgentChatMenuHandlers.bind(into: registry, context: context)
        AgentConfigurationHandlers.bind(into: registry, context: context)
        AgentChatKeyHandlers.bind(into: registry, context: context)
        CloudHandlers.bind(into: registry, context: context)
        AccountsHandlers.bind(into: registry, context: context)
        ProfileMenuHandlers.bind(into: registry, context: context)
        RemoteHandlers.bind(into: registry, context: context)
        SSHTargetHandlers.bind(into: registry, context: context)
        ResumeCommandHandlers.bind(into: registry, context: context)
        RemoteGroupHandlers.bind(into: registry, context: context)
        ChiefMoveHandlers.bind(into: registry, context: context)
        ChiefMemoryImportHandlers.bind(into: registry, context: context)
        RemoteBrowserPages.bind(into: registry, context: context)
        ResourceHandlers.bind(into: registry, context: context)
        LinkHandlers.bind(into: registry, context: context)
        IconMenuVisibility.install(registry, context: context)
        TabSelectionTitles(context: context).install(in: registry)
        TopPages.installTabTargetReasons(services)
        ActionTargetReasons.refuseHeadlessNameEditors(in: registry) { RefusalStrings.nameArgumentRequired }
        HomeRules.install(services)
        TopPages.registerProviders(services)
        context.observeRefusals()
        DestructiveConfirmation.install(services)
        ActionRouting.install(services)
        ActionRouting.installSidebarUserIntent(services)
        WindowKeyTable.install(services)
        // One owner per action: a second binding silently replaces the first. The check is a test
        // (noActionIsBoundTwice); at runtime a Debug dogfood build must not crash, so only a fault.
        if !registry.duplicateBindings.isEmpty {
            Logger(subsystem: "com.cmuxterm.app.next", category: "actions").fault("actions bound twice: \(registry.duplicateBindings.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        }
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
                let scripted = registry.isCapturingRefusal
                let origin = try QuitPolicy.origin(for: invocation, scripted: scripted)
                // A scripted quit saves unsaved documents first and refuses,
                // naming them, when a save fails (R96 quit hook).
                guard scripted, !services.quit.unsaved.unsaved().isEmpty else { return services.quit.requestQuit(origin) }
                registry.track(Task { @MainActor in
                    if let refusal = QuitUnsavedStep.refusal(await QuitUnsavedStep.saveUnattended(services.quit.unsaved)) {
                        return ActionWorkFailure(refusal)
                    }
                    services.quit.requestQuit(origin)
                    return nil
                })
            } catch {
                registry.refuse(QuitArgumentConflict.reason)
            }
        })
        registry.bind("quitKeepSessions") { services.quit.requestQuit(.explicit(.keep)) }
        registry.bind("quitEndSessions") { services.quit.requestQuit(.explicit(.endKeepLayout)) }
        registry.bind("quitEndEverything") { services.quit.requestQuit(.explicit(.endEverything)) }
        // action-wait-allow: a window opens only once the daemon reports its first workspace (as New Window always did); the new space is created there first.
        registry.bind("newWindow", invoke: { RoomHandlers.newWindow($0, AppActionContext(services: services)) })
        registry.bind("newIncognitoWindow") { services.windows.newIncognitoWindow() }
        registry.bind("closeWindow", isEnabled: { services.windows.active != nil }) {
            services.windows.active?.window?.performClose(nil)
        }
        registry.bind("toggleFullScreen") { services.windows.active?.window?.toggleFullScreen(nil) }
        registry.bind("toggleSidebar") { services.windows.active?.sidebar.model.toggle() }
        // The workspace list takes the keyboard; a hidden sidebar shows first.
        // Keyboard focus there survives the workspace switches its arrows make.
        registry.bind("focusSidebar") {
            guard let window = services.windows.active else { return }
            if window.sidebar.model.isHidden { window.sidebar.model.toggle() }
            window.sidebar.container.sidebarView.focusList()
            window.focus.send(.focusTarget(.sidebar(keyboard: true), source: .keyboard))
        }
    }
}
