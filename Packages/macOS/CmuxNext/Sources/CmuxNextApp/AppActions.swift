import AppKit
import CmuxNextActions
import class CmuxNextControl.LaunchBinderLaps
import CmuxNextAgentPane
import CmuxNextAgentLanes
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebarActions
import CmuxNextWorkspaceNaming

/// Binds catalog actions to handlers. Menus, shortcuts, the palette, and
/// context menus all resolve through the registry (REWRITE.md "Action
/// contract"), so each behavior is written once here.
enum AppActions {
    static func bind(_ services: AppServices, laps: LaunchBinderLaps = LaunchBinderLaps(), deferring: Bool = false) { // laps: each binder's time, for the launch-times row; deferring (the launch): bindDeferred waits for the first frame
        bindApp(services); laps.lap("bindApp")
        bindWorkspaces(services); laps.lap("bindWorkspaces")
        bindBrowser(services); laps.lap("bindBrowser")
        let registry = services.registry, context = AppActionContext(services: services)
        WindowHandlers.bind(into: registry, context: context); laps.lap("WindowHandlers.bind")
        // Pin/Unpin Chat on a history row: bound with the app's actions, with or without a local acpmux (the
        // Chats feed only fills the history; a launch without one used to leave the action unbound).
        SidebarChatHistoryFeed.bind(into: registry); laps.lap("SidebarChatHistoryFeed.bind")
        FilesPaneHandlers.bind(into: registry, context: context); laps.lap("FilesPaneHandlers.bind")
        TabSearchHandlers.bind(into: registry, context: context); laps.lap("TabSearchHandlers.bind")
        PaletteScopeHandlers.bind(into: registry, context: context); laps.lap("PaletteScopeHandlers.bind")
        AppStoreHandlers.bind(into: registry, context: context); laps.lap("AppStoreHandlers.bind")
        CustomSidebarToggle(apps: { [weak services] in services?.apps.client }, environment: ProcessInfo.processInfo.environment, window: { [weak services] in services?.windows.active?.window }).bind(into: registry); laps.lap("CustomSidebarToggle")
        TasksHandlers.bind(into: registry, context: context); laps.lap("TasksHandlers.bind")
        TaskManagerHandlers.bind(into: registry, context: context); laps.lap("TaskManagerHandlers.bind")
        KeybindingHandlers.bind(into: registry, context: context); laps.lap("KeybindingHandlers.bind")
        PageCommandHandlers.bind(into: registry, context: context); laps.lap("PageCommandHandlers.bind")
        ListHandlers.bind(into: registry, context: context); laps.lap("ListHandlers.bind")
        PasswordHandlers.bind(into: registry, context: context); laps.lap("PasswordHandlers.bind")
        CloudPageHandlers.bind(into: registry, context: context); laps.lap("CloudPageHandlers.bind")
        WorkspaceHandlers.bind(into: registry, context: context); laps.lap("WorkspaceHandlers.bind")
        WorkspaceVerbHandlers.bind(into: registry, context: context); laps.lap("WorkspaceVerbHandlers.bind")
        WorkspaceStructureHandlers.bind(into: registry, context: context); laps.lap("WorkspaceStructureHandlers.bind")
        WorkspaceMetadataHandlers.bind(into: registry, context: context); laps.lap("WorkspaceMetadataHandlers.bind")
        WorkspaceActivityNameActions(host: services).bind(into: registry); laps.lap("WorkspaceActivityNameActions")
        WorkspaceNotesHandlers.bind(into: registry, context: context); laps.lap("WorkspaceNotesHandlers.bind")
        WorkspaceChecklistHandlers.bind(into: registry, context: context); laps.lap("WorkspaceChecklistHandlers.bind")
        WorkspaceGroupHandlers.bind(into: registry, context: context); laps.lap("WorkspaceGroupHandlers.bind")
        SidebarActionSet(host: services, autoArchive: services.autoArchive, settings: { [weak services] in services?.settings }, sidebar: { [weak services] in services?.windows.active?.sidebar.container.sidebarView }, themeColors: { [weak services] in services?.themes.catalog.colors ?? [:] }, playgroundSections: { [HomeFilterPlaygroundSection().section()] }).bind(into: registry); laps.lap("SidebarActionSet")
        NotificationSoundActions(host: services, gate: services.notifications.soundGate).bind(into: registry); laps.lap("NotificationSoundActions")
        RoomHandlers.bind(into: registry, context: context); laps.lap("RoomHandlers.bind")
        PaletteVerbActions(host: services).bind(into: registry); laps.lap("PaletteVerbActions")
        RoomMenuHandlers.bind(into: registry, context: context); laps.lap("RoomMenuHandlers.bind")
        ThemeHandlers.bind(into: registry, context: context); laps.lap("ThemeHandlers.bind")
        RemoteLocalhostHandlers.bind(into: registry, context: context); laps.lap("RemoteLocalhostHandlers.bind")
        WindowMembershipHandlers.bind(into: registry, context: context); laps.lap("WindowMembershipHandlers.bind")
        SidebarHandlers.bind(into: registry, context: context); laps.lap("SidebarHandlers.bind")
        SidebarSectionHandlers.bind(into: registry, context: context); laps.lap("SidebarSectionHandlers.bind")
        SidebarHiddenSections.bind(into: registry, context: context); laps.lap("SidebarHiddenSections.bind")
        SidebarPriorityFeed.bind(into: registry, context: context); laps.lap("SidebarPriorityFeed.bind")
        SidebarGroupByActions.bind(into: registry, context: context); laps.lap("SidebarGroupByActions.bind")
        VerticalTabsActions(host: context, store: services.workspaceVerticalTabs).bind(into: registry); laps.lap("VerticalTabsActions")
        SidebarMinimalToggle.bind(into: registry, context: context); laps.lap("SidebarMinimalToggle.bind")
        AgentChatRailActions(settings: { [weak services] in services?.settings }, managed: RefusalStrings.settingManaged, notLoaded: RefusalStrings.settingsNotLoaded).bind(into: registry); laps.lap("AgentChatRailActions")
        SidebarDensityActions.bind(into: registry, context: context); laps.lap("SidebarDensityActions.bind")
        SettingsHandlers.bind(into: registry, context: context); laps.lap("SettingsHandlers.bind")
        AppearanceHandlers.bind(into: registry, context: context); laps.lap("AppearanceHandlers.bind")
        PaneBackgroundHandlers(context: context).bind(into: registry); laps.lap("PaneBackgroundHandlers")
        DensityHandlers.bind(into: registry, context: context); laps.lap("DensityHandlers.bind")
        FocusRingHandlers.bind(into: registry, context: context); laps.lap("FocusRingHandlers.bind")
        HibernationHandlers.bind(into: registry, context: context); laps.lap("HibernationHandlers.bind")
        TabHandlers.bind(into: registry, context: context); laps.lap("TabHandlers.bind")
        TabIconHandlers.bind(into: registry, context: context); laps.lap("TabIconHandlers.bind")
        TabGroupHandlers.bind(into: registry, context: context); laps.lap("TabGroupHandlers.bind")
        GroupIconHandlers.bind(into: registry, context: context); laps.lap("GroupIconHandlers.bind")
        MachineIconHandlers.bind(into: registry, context: context); laps.lap("MachineIconHandlers.bind")
        PaneHandlers.bind(into: registry, context: context); laps.lap("PaneHandlers.bind")
        DividerActions(host: services).bind(into: registry); laps.lap("DividerActions")
        ColumnHandlers.bind(into: registry, context: context); laps.lap("ColumnHandlers.bind")
        NewAtPlacement.bind(into: registry, context: context); laps.lap("NewAtPlacement.bind")
        CanvasHandlers.bind(into: registry, context: context); laps.lap("CanvasHandlers.bind")
        ColumnDocking.bind(into: registry, context: context); laps.lap("ColumnDocking.bind")
        ColumnAvailability.bind(into: registry, context: context); laps.lap("ColumnAvailability.bind")
        ScreenHandlers.bind(into: registry, context: context); laps.lap("ScreenHandlers.bind")
        BrowserHandlers.bind(into: registry, context: context); laps.lap("BrowserHandlers.bind")
        ScreenshotHandlers.bind(into: registry, context: context); laps.lap("ScreenshotHandlers.bind")
        DevToolsHandlers.bind(into: registry, context: context); laps.lap("DevToolsHandlers.bind")
        context.services.keyRouter.keyModes.bind(into: registry); laps.lap("context.services.keyRouter.keyModes.bind")
        ChiefUsagePageTab.bind(into: registry, context: context); laps.lap("ChiefUsagePageTab.bind")
        ChiefViewsPageTab.bind(into: registry, context: context); laps.lap("ChiefViewsPageTab.bind")
        PhoneHandlers.bind(into: registry, context: context); laps.lap("PhoneHandlers.bind")
        BrowserHitHandlers.bind(into: registry, context: context); laps.lap("BrowserHitHandlers.bind")
        DiffHandlers.bind(into: registry, context: context); laps.lap("DiffHandlers.bind")
        FilePageHandlers.bind(into: registry, context: context); laps.lap("FilePageHandlers.bind")
        AgentExtensionHandlers.bind(into: registry, context: context); laps.lap("AgentExtensionHandlers.bind")
        ViewerHandlers.bind(into: registry, context: context); laps.lap("ViewerHandlers.bind")
        PageInfoHandlers.bind(into: registry, context: context); laps.lap("PageInfoHandlers.bind")
        CertificateWarningHandlers.bind(into: registry, context: context); laps.lap("CertificateWarningHandlers.bind")
        ExtensionHandlers.bind(into: registry, context: context); laps.lap("ExtensionHandlers.bind")
        BrowserToolbarHandlers.bindMenuRows(into: registry, context: context); laps.lap("BrowserToolbarHandlers.bindMenuRows")
        BrowserProfileHandlers.bind(into: registry, context: context); laps.lap("BrowserProfileHandlers.bind")
        OpenInHandlers.bind(into: registry, context: context); laps.lap("OpenInHandlers.bind")
        NotificationHandlers.bind(into: registry, context: context); laps.lap("NotificationHandlers.bind")
        bindAttentionPalette(into: registry, context: context); laps.lap("bindAttentionPalette")
        AgentHandlers.bind(into: registry, context: context); laps.lap("AgentHandlers.bind")
        AgentChatMenuHandlers.bind(into: registry, context: context); laps.lap("AgentChatMenuHandlers.bind")
        AgentChatMenuHandlers.bindEditors(into: registry, context: context); laps.lap("AgentChatMenuHandlers.bindEditors")
        AgentConfigurationHandlers.bind(into: registry, context: context); laps.lap("AgentConfigurationHandlers.bind")
        AgentChatKeyHandlers.bind(into: registry, context: context); laps.lap("AgentChatKeyHandlers.bind")
        CloudHandlers.bind(into: registry, context: context); laps.lap("CloudHandlers.bind")
        DaemonStartupWait(daemon: services.daemon).bind(into: registry); laps.lap("DaemonStartupWait")
        RemoteHandlers.bind(into: registry, context: context); laps.lap("RemoteHandlers.bind")
        SSHTargetHandlers.bind(into: registry, context: context); laps.lap("SSHTargetHandlers.bind")
        ResumeCommandHandlers.bind(into: registry, context: context); laps.lap("ResumeCommandHandlers.bind")
        RemoteGroupHandlers.bind(into: registry, context: context); laps.lap("RemoteGroupHandlers.bind")
        SidebarScreenIntentActions.bindViewScreen(into: registry) { [weak services] in services?.windows.active.map { window in (sections: window.sidebar.model.sections, handle: { @MainActor intent in window.sidebar.handle(intent) }) } }; laps.lap("SidebarScreenIntentActions.bindViewScreen")
        ChiefMoveHandlers.bind(into: registry, context: context); laps.lap("ChiefMoveHandlers.bind")
        RemoteBrowserPages.bind(into: registry, context: context); laps.lap("RemoteBrowserPages.bind")
        ResourceHandlers.bind(into: registry, context: context); laps.lap("ResourceHandlers.bind")
        LinkHandlers.bind(into: registry, context: context); laps.lap("LinkHandlers.bind")
        if !deferring { bindDeferred(services, laps: laps) }
        // Last: a catalog row with a daemon request and no handler above sends it (cmux-action-catalog `Action::request`); deferring, a fallback the deferred binder replaces.
        registry.bindingFallbacks(deferring) { CatalogRequestHandlers(host: services).bind(into: registry); laps.lap("CatalogRequestHandlers"); HandlerPlaceholders.bind(into: registry); laps.lap("HandlerPlaceholders.bind") }
        IconMenuVisibility.install(registry, context: context); laps.lap("IconMenuVisibility.install")
        SpacesMenuVisibility { [weak services] in services.map { SidebarSpaceBar.profiles($0.machines.local, window: $0.windows.active?.state.id ?? "", windows: $0.windows).count } ?? 0 }.install(in: registry); laps.lap("SpacesMenuVisibility")
        TabSelectionTitles(context: context).install(in: registry); laps.lap("TabSelectionTitles")
        TopPages.installActionRules(services); laps.lap("TopPages.installActionRules")
        ActionTargetReasons.refuseHeadlessNameEditors(in: registry) { RefusalStrings.nameArgumentRequired }; laps.lap("ActionTargetReasons.refuseHeadlessNameEditors")
        HomeRules.install(services); laps.lap("HomeRules.install")
        TopPages.registerProviders(services); laps.lap("TopPages.registerProviders")
        context.observeRefusals(); laps.lap("context.observeRefusals")
        DestructiveConfirmation.install(services); laps.lap("DestructiveConfirmation.install")
        ActionRouting.install(services); laps.lap("ActionRouting.install")
        ActionRouting.installUserIntentObservers(services); laps.lap("ActionRouting.installUserIntentObservers")
        WindowKeyTable.install(services); laps.lap("WindowKeyTable.install")
    }

    /// After the first frame at launch (startup-under-100ms): binders no setting, restored tab (no page provider) or first-frame view reads, and no rule amends.
    static func bindDeferred(_ services: AppServices, laps: LaunchBinderLaps = LaunchBinderLaps()) { let registry = services.registry, context = AppActionContext(services: services)
        HistoryHandlers.bind(into: registry, context: context); laps.lap("post_frame.HistoryHandlers"); StashHandlers.bind(into: registry, context: context); laps.lap("post_frame.StashHandlers")
        BookmarkHandlers.bind(into: registry, context: context); laps.lap("post_frame.BookmarkHandlers"); BookmarkIconHandlers.bind(into: registry, context: context); laps.lap("post_frame.BookmarkIconHandlers")
        ServerHandlers.bind(into: registry, context: context); laps.lap("post_frame.ServerHandlers"); VaultHandlers.bind(into: registry, context: context); laps.lap("post_frame.VaultHandlers")
        FindInDirectoryHandlers.bind(into: registry, context: context); laps.lap("post_frame.FindInDirectoryHandlers"); GlobalSearchHandlers.bind(into: registry, context: context); laps.lap("post_frame.GlobalSearchHandlers")
        HintHandlers.bind(into: registry, context: context); laps.lap("post_frame.HintHandlers"); MusicHandlers.bind(into: registry, context: context); laps.lap("post_frame.MusicHandlers")
        VoiceRoomHandlers.bind(into: registry, context: context); laps.lap("post_frame.VoiceRoomHandlers"); NowPlayingCardHandlers.bind(into: registry, context: context); laps.lap("post_frame.NowPlayingCardHandlers")
        PictureInPictureHandlers.bind(into: registry, context: context); laps.lap("post_frame.PictureInPictureHandlers"); StatsPageTab.bind(into: registry, context: context); laps.lap("post_frame.StatsPageTab")
        AccountsHandlers.bind(into: registry, context: context); laps.lap("post_frame.AccountsHandlers"); ProfileMenuHandlers.bind(into: registry, context: context); laps.lap("post_frame.ProfileMenuHandlers")
        TerminalHandlers.bind(into: registry, context: context); laps.lap("post_frame.TerminalHandlers") // read only by keys, menus and palette rows opened after the frame; the gate runs this before any input
    }

    static func scope(_ services: AppServices, _ invocation: ActionInvocation = ActionInvocation()) -> ActionScope {
        ActionScope(services: services, invocation: invocation)
    }

    /// Binds the app-owned palette action for the agent-pane attention projection.
    /// The projection itself lives in CmuxNextAgentPane; only the app can reveal a
    /// tab on its owning machine and present the palette.
    private static func bindAttentionPalette(into registry: ActionRegistry, context: AppActionContext) {
        let tabs = context.services.attentionTabs
        tabs.onOpen = { [weak services = context.services, weak tabs] key in
            guard let services, let tabs,
                  tabs.items.contains(where: { $0.tabId == key }),
                  let (daemon, tab, requestID) = AttentionTabsWatch.locate(key, in: services.machines.daemons, machineID: \.machineID)
            else { return false }
            // The row is a snapshot. Refuse a stale click if the mark was cleared or the id was
            // reused before the page's request arrived.
            guard daemon.supports(DaemonCapability.tabAttentionRequestID.rawValue),
                  daemon.store.tab(idOrResource: tab)?.attention?.requestID == requestID else { return false }
            return services.revealTab(tab, onMachine: daemon.machineID)
        }
        tabs.onChange = { [weak services = context.services] in
            guard let model = services?.palette.model, model.currentPageID == AttentionPalettePage.pageID else { return }
            model.reload()
        }
        context.services.palette.sources.actionPages[AttentionPalettePage.id] = { AttentionPalettePage(tabs: tabs).page() }
        registry.bindEffect(AttentionPalettePage.id, requires: nil, effect: { invocation in
            guard invocation.allowsViewChange else { throw ActionFailure(message: AttentionPalettePage.needsFocus) }
            let page = AttentionPalettePage(tabs: tabs)
            guard !page.tabs.items.isEmpty else { throw ActionFailure(message: AttentionPalettePage.nothing) }
            context.services.palette.show(page: page.page(), relativeTo: context.activeWindow?.window)
            return .done
        })
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
                let origin = try QuitOrigin(for: invocation, scripted: scripted)
                // Cmd-Q's first press only warns (`app.warnBeforeQuitShortcut`); the menu, Dock and scripts quit.
                if !scripted, origin == .interactive, services.quit.holdsShortcutQuit(invocation) { return }
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
            services.windows.active?.window?.closeWithoutButtonFlash()
        }
        registry.bind("toggleFullScreen") { services.windows.active?.window?.toggleFullScreen(nil) }
        ActionTargetTitles.setPaletteState("toggleFullScreen", in: registry) { services.windows.active?.window?.styleMask.contains(.fullScreen) == true }
        registry.bind("toggleSidebar") { services.windows.active?.sidebar.model.toggle(timing: services.frameTiming) }
        ActionTargetTitles.setPaletteState("toggleSidebar", in: registry) { services.windows.active?.sidebar.model.isHidden == false }
        // The workspace list takes the keyboard; a hidden sidebar shows first.
        // Keyboard focus there survives the workspace switches its arrows make.
        registry.bind("focusSidebar") {
            guard let window = services.windows.active else { return }
            if window.sidebar.model.isHidden { window.sidebar.model.toggle() }
            window.sidebar.container.sidebarView.focusList()
            window.focus.send(.focusTarget(.sidebar(keyboard: true), source: .intent)) // the CLI's run is not the person's intent
        }
    }
}
