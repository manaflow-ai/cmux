public import Foundation
import CmuxNextActions
public import CmuxNextDesign

/// The parts of cmux.json that cmux-next applies, parsed off the main actor.
/// Keys stay strings here; `SettingsApplier` maps them onto `DesignSettings`
/// and the action registry on the main actor.
public struct CmuxConfigSnapshot: Sendable, Equatable {
    /// The whole document, for `settings.get`.
    public var root: JSONValue
    /// `appearance.density`, when present and valid: a built-in density's id.
    public var density: String?
    /// `appearance.customDensities` (``CustomDensitiesSetting``), in file order.
    public var customDensities: [DensityTokens] = []
    /// `appearance.customDensity` when it names one of `customDensities`: it wins over `density`.
    public var customDensity: String?
    /// The density the file selects: the custom one, else the built-in, else Compact.
    public var selectedDensity: DensityTokens {
        DensitySetting.resolve(customDensity, custom: customDensities) ?? DensitySetting.resolve(density, custom: []) ?? .compact
    }
    /// `app.uiScale` (first-party page scale) and `appearance.interfaceScale` (chrome, only with Labs on).
    public var uiScale: Double = UIScaleSetting().fallback
    public var interfaceScale: Double = InterfaceScaleSetting().fallback
    /// `appearance.metrics.<name>` in points.
    public var metrics: [String: Double]
    /// Shortcut bindings by action ID: `shortcuts.bindings.<id>` merged with
    /// direct `shortcuts.<id>` keys (direct keys win, as in the old loader).
    /// The classic 0.30 second modifier-hold hint preference.
    public var showModifierHoldHints = ModifierHoldHintsSetting().fallback
    public var shortcuts: [String: ShortcutBinding]
    /// Key routing tiers by action ID (`shortcuts.tiers.<id>`: `system`,
    /// `navigation` or `content`), plans/cmux-next/focus.md section 5.
    public var keyTiers: [String: String] = [:]
    /// `layout.panePadding`, `layout.paneCornerRadius`, `layout.paneBorder`.
    public var paneChrome = PaneChromeOverrides()
    /// `ui.surfaceTabBar.buttons`, resolved; the defaults when unset.
    public var tabBar: SurfaceTabBarConfig = .defaults
    /// Runnable `actions.<name>` entries plus inline command buttons.
    public var commandActions: [ConfigCommandAction] = []
    /// `browser.defaultEngine`; Chromium when unset or invalid.
    public var browserDefaultEngine: BrowserDefaultEngine = .fallback
    /// `browser.siteEngines`; the protected-media sites on WebKit when unset.
    public var browserSiteEngines: BrowserSiteEngines = .fallback
    /// `browser.newTabPage`; nil opens a blank page.
    public var browserNewTabPage: URL?
    /// `browser.showBookmarksBar`; off when unset.
    public var browserShowBookmarksBar = false
    /// `browser.import.enabled`; on when unset or invalid.
    public var browserImportEnabled: Bool = BrowserImportSetting.fallback
    /// `browser.import.cookieBanner`; on when unset or invalid (``BrowserCookieBannerSetting``).
    public var browserImportCookieBanner = BrowserCookieBannerSetting().fallback
    /// `home.chiefBubbleStyle`: the Chief chat's bubbles, `imessage` (Messages' blue and grey) when unset or `theme`.
    public var homeChiefBubbleStyle = HomeChiefBubbleStyleSetting.defaultStyle
    /// `home.bubbleColors.*`: the bubble colours every Home chat starts with, `#RRGGBB` by role (`sent`,
    /// `sentText`, `received`, `receivedText`); an unset role keeps the bubble style's.
    public var homeBubbleColors: [String: String] = [:]
    /// `chief.reactionsCanWake`, `chief.reactionClassifier.*`: whether a tapback can wake the Chief, and the classifier (Claude Haiku) that decides.
    public var chiefReactions = ChiefReactionSettings.fallback
    /// `browser.builtInAdBlocker`; on when unset.
    public var browserBuiltInAdBlocker = BuiltInAdBlockerSetting().fallback
    /// `browser.showAgentCursor`; on when unset.
    public var browserShowAgentCursor = AgentCursorSetting().fallback
    /// `browser.agentMouse.*`: how an agent's pointer moves; human motion,
    /// 350 ms cap when unset.
    public var browserAgentMouse = AgentMouseSetting().fallback
    /// `home.attachments.keepLocation` (off: strip location) and `home.channelsEnabled`; off when unset.
    public var homeKeepLocation = false, homeChannelsEnabled = false, homeChiefPetEnabled = false, homeChiefPetMascot = HomeChiefPetSetting.defaultMascot
    /// `home.feedInChief`: the main Chief's conversation shows the Feed's notices; on when unset.
    public var homeFeedInChief = true
    /// `home.server`: cmux Cloud (`hosted`) when unset or invalid, else the self-hosted server's origin.
    public var homeServer: HomeServerSetting.Value = .hosted
    /// `labs.previewFeatures` and `labs.classicHome`; off when unset.
    public var previewFeatures = CmuxConfigSnapshot.previewFeaturesDefault, classicHome = CmuxConfigSnapshot.classicHomeDefault
    /// `labs.voiceRoom` (off when unset) and `labs.voiceRoomURL` (trimmed; empty is the local room server).
    public var voiceRoom = CmuxConfigSnapshot.voiceRoomDefault, voiceRoomURL = CmuxConfigSnapshot.voiceRoomURLDefault
    /// `labs.machineJoin`: the one-line machine join surfaces (Add Device's way, joined Machines rows, This Mac's
    /// consent switches); off when unset.
    public var machineJoin = CmuxConfigSnapshot.machineJoinDefault
    /// `browser.hibernation`, `browser.hibernationExclusions`, `browser.hibernatePinnedTabs`, `browser.freezeHiddenTabs`.
    public var browserHibernation: BrowserHibernationSetting = .fallback
    /// `browser.links.*`: what modified link clicks do; Chrome's when unset.
    public var browserLinkClicks: BrowserLinkClickSetting = .fallback
    /// `browser.openLinksInCmuxBrowser` (classic: `.openTerminalLinksInCmuxBrowser`), `.hostsToOpenInEmbeddedBrowser`, `.urlsToAlwaysOpenExternally`.
    public var linkRouting: LinkRouting = .fallback
    /// `terminal.linkOpener.default` and `.rules`: where a URL a terminal program opens goes; cmux first when unset.
    public var terminalLinkOpener: TerminalLinkOpener = .fallback
    /// `files.textEditor`: the app for a path's Open in Text Editor; empty for the system's.
    public var textEditor = TextEditorSetting()
    /// `browser.searchEngine`, `browser.customSearchEngine.*`, `browser.omnibar.*`.
    public var browserOmnibar = BrowserOmnibarSetting.fallback
    /// `agentPane.editedFiles.*`: the agent pane's edited-files card.
    public var agentPaneEditedFiles = AgentPaneEditedFilesSetting.fallback
    public var agentPaneZoom: Double = AgentPaneZoomSetting.fallback
    public var agentPaneComposer = AgentPaneComposerSetting.fallback
    /// `browser.remoteLocalhost` and `browser.remoteLocalhostWorkspaces`.
    public var remoteLocalhost: RemoteLocalhostSetting = .fallback
    /// `ui.animationSpeed`; "fast" when unset or invalid.
    public var animationSpeed: MotionSpeed = AnimationSpeedSetting.fallback
    public var animationKinds = AnimationKindsSetting()
    /// `ui.animations.enabled` and `ui.animations.<category>` (``MotionCategoriesSetting``).
    public var motionCategories = MotionCategoriesSetting()
    /// `ui.calm`; off when unset or invalid.
    public var calmMode: CalmMode = CalmModeSetting.fallback
    /// `ui.paneAnimations`; on when unset or invalid.
    public var paneAnimations: Bool = PaneAnimationsSetting.fallback
    /// `layout.centerFocusedColumn`; "never" when unset or invalid.
    public var centerFocusedColumn: CenterFocusedColumn = CenterFocusedColumnSetting.fallback
    /// `layout.stripScrollbar`; "auto" when unset or invalid.
    public var stripScrollbar: StripScrollbarMode = StripScrollbarSetting.fallback
    public var sidebarSections = SidebarSectionsPreferences.defaults
    /// `sidebar.hoverCards.*`: hover cards on, and their delay.
    public var hoverCards = HoverCardSettings()
    /// `workspaceGroups`: the global and per-group settings of workspace groups.
    public var workspaceGroups = WorkspaceGroupConfig()
    /// `sidebar.nowPlaying.*`: the Now Playing player shows.
    public var nowPlaying = NowPlayingSettings()
    /// `appearance.colorTransition.*` (cx-3rf4z).
    public var colorTransition = ColorTransitionSetting()
    /// `layout.splitSizing`, `layout.newColumnWidth`, docked defaults and the
    /// minimum pane size (`ColumnLayoutSettings`).
    public var splitSizing: SplitSizing = ColumnLayoutSettings.splitSizingFallback
    public var newColumnWidth: NewColumnWidthMode = ColumnLayoutSettings.newColumnWidthFallback
    public var dockColumnEdge: DockDefaultEdge = ColumnLayoutSettings.dockEdgeFallback
    public var dockColumnMode: DockDefaultMode = ColumnLayoutSettings.dockModeFallback
    /// `layout.frameOrientation`: which docks own the frame's corners.
    public var frameOrientation: FrameOrientation = ColumnLayoutSettings.frameOrientationFallback
    /// `layout.rows`: rows on (default) or off (plans/cmux-next/rows.md O1).
    public var layoutRows: Bool = ColumnLayoutSettings.rowsFallback
    /// `layout.focusFollowsMouse`: hovering or scrolling an unfocused pane focuses it (default off).
    public var focusFollowsMouse: Bool = ColumnLayoutSettings.focusFollowsMouseFallback
    /// `layout.scrollAreas`: splits that cannot fit scroll instead of squashing (default off;
    /// plans/cmux-next/scroll-areas-DESIGN.md).
    public var layoutScrollAreas: Bool = ColumnLayoutSettings.scrollAreasFallback
    /// `layout.scrollModifier`: which scroll moves the layout (``LayoutScrollModifier``).
    public var layoutScrollModifier: LayoutScrollModifier = ColumnLayoutSettings.scrollModifierFallback
    /// `layout.pagesHandleCommandScroll`: a web page that cancels Command + wheel keeps a Command scroll over it.
    public var pagesHandleCommandScroll: Bool = ColumnLayoutSettings.pagesHandleCommandScrollFallback
    public var minimumPaneContentSize = CGSize(width: ColumnLayoutSettings.minimumPaneWidthFallback,
                                               height: ColumnLayoutSettings.minimumPaneHeightFallback)
    /// `layout.newPanePlacement` and `layout.tileBrowsers` (`CmuxConfigSnapshot+PanePlacement`).
    public var newPanePlacement: NewPanePlacement = CmuxConfigSnapshot.newPanePlacementFallback
    public var tileBrowsers: Bool = CmuxConfigSnapshot.tileBrowsersFallback
    /// `layout.linkPlacement`: where an opened link or path lands (``LinkPlacement``).
    public var linkPlacement: LinkPlacement = .fallback
    /// `layout.mainPane`: whether an agent chat is its screen's main pane (``MainPaneSetting``).
    public var mainPane: MainPaneSetting = .fallback
    /// `workspaces.newPlacement` (`WorkspaceListSettings`).
    public var newWorkspacePlacement: NewWorkspacePlacement = CmuxConfigSnapshot.newWorkspacePlacementFallback
    /// `layout.closeFocus`; "previousNeighbor" when unset or invalid.
    public var closeFocus: CloseFocusPolicy = CloseFocusSetting.fallback
    /// `layout.defaultColumnWidth`; two thirds when unset or invalid.
    public var defaultColumnWidth: Double = DefaultColumnWidthSetting.fallback
    /// `focusRing.*`.
    public var focusRing = FocusRingSettings()
    /// `sidebar.border` and `sidebar.borderWidth`; an unset border follows
    /// `chromeStyle`.
    public var sidebarBorder = SidebarBorder()
    /// `appearance.chromeStyle`: the defaults of the finer chrome keys.
    public var chromeStyle: ChromeStyle = ChromeStyleSetting.fallback
    /// `notifications.attention.*`.
    public var attention = AttentionSettings()
    /// `appearance.backgroundOpacity` and `appearance.backgroundBlur`; both nil (Ghostty's values) when unset or invalid.
    public var windowBackground = WindowBackgroundOverride()
    /// `appearance.inactiveWindowDim`: 0 unless set.
    public var inactiveWindowDim = 0.0
    /// `appearance.wallpaperTint`: on unless set to false.
    public var wallpaperTint = WallpaperTintSetting.fallback
    /// `appearance.surfaces.<surface>.color|opacity` (R55); no override
    /// (every surface shows the window's backdrop) when unset or invalid.
    public var surfaceBackgrounds = SurfaceBackgrounds.none
    /// The bundled art of ``backdropSelection``; nil for none or another source.
    public var backdropArt: BackdropArt? = BackdropSelectionSetting.defaultArt
    /// `appearance.background`: ``BackdropSelectionSetting/defaultSelection`` (off) when unset,
    /// nil for `none`.
    public var backdropSelection: BackdropSelection? = BackdropSelectionSetting.defaultSelection
    /// `ui.reducedBackgrounds`: off when unset or invalid. On, windows draw the plain theme
    /// background; ``backdropSelection`` and ``windowBackground`` keep the person's values.
    public var reducedBackgrounds: Bool = ReducedBackgroundsSetting.fallback
    /// `appearance.experimentalControls`; off unless explicitly enabled.
    public var experimentalAppearance = false
    /// `appearance.glassTransparency`, `appearance.hue` and
    /// `appearance.saturation`; identity values when unset or invalid.
    public var appearanceTuning = AppearanceTuningSetting.fallback
    /// The tuning the window tint takes: ``appearanceTuning`` while Experimental Appearance
    /// Controls is on, else none.
    public var windowTuning: AppearanceTuning { experimentalAppearance ? appearanceTuning : .identity }
    /// `appearance.statusIndicator.*`.
    public var statusIndicator = StatusIndicatorSettings()
    /// `status.*`.
    public var statusBehavior = StatusBehaviorSettings()
    /// `appearance.borders`; "default" when unset or invalid.
    public var borders: BorderMode = BordersSetting.fallback
    /// `appearance.focusIndicator`; "tabs" when unset or invalid.
    public var focusIndicator: FocusIndicator = PaneFocusSettings.focusIndicatorFallback
    /// `focus.inactiveTabStyle`; "fade" when unset or invalid.
    public var inactiveTabStyle: InactiveTabStyle = PaneFocusSettings.inactiveTabStyleFallback
    /// `window.titlebar`; "minimal" when unset or invalid.
    public var titlebar: TitlebarStyle = WindowTitlebarSetting.fallback
    /// `window.titlebarButtons`; "hover" when unset or invalid.
    public var titlebarButtons: TitlebarButtonsMode = TitlebarButtonsSetting.fallback
    /// `tabs.plusButton`; "hover" when unset or invalid.
    public var plusButton: PlusButtonMode = PlusButtonSetting.fallback
    /// `sidebar.side` and `sidebar.spacesPosition` (R109).
    public var sidebarSide: SidebarSide = .left
    public var spacesPosition: SpacesPosition = .bottom
    /// `sidebar.spacesVisibility` (cx-5k3r); "hover" when unset or invalid.
    public var spacesVisibility: SpacesVisibilityMode = .hover
    /// `tabs.barPosition` (R109).
    public var tabBarPosition: TabBarPosition = .top
    /// `appearance.paneBackgrounds`: one background for the window or one per pane.
    public var paneBackgrounds: PaneBackgroundMode = .shared
    /// `tabs.barOrder` (R109).
    public var tabBarOrder: TabBarOrder = .aboveToolbar
    /// `browser.toolbarPosition`: the omnibar row of browser and Markdown panes.
    public var browserToolbarPosition: ToolbarPosition = .top
    /// `app.quitBehavior`; "ask" when unset or invalid.
    public var quitBehavior: QuitBehavior = QuitBehaviorSetting.fallback
    /// `newTerminal.opensWorkspace`; off when unset or invalid.
    public var newTerminalOpensWorkspace: Bool = NewTerminalWorkspaceSetting.fallback
    /// `tabs.cmdWClosesPinnedTabs`; on when unset or invalid.
    public var cmdWClosesPinnedTabs: Bool = CmdWClosesPinnedTabsSetting.fallback
    /// `tabs.nativeNewTabPage`: the native (Swift) New Tab page instead of the web one; off when unset or invalid.
    public var nativeNewTabPage: Bool = NativeNewTabPageSetting.fallback
    /// `tabs.overflow`; shrink when unset or invalid.
    public var tabOverflow: TabOverflow = TabOverflowSetting.fallback
    /// `tabs.swapCmdTAndCmdN`; off when unset or invalid.
    public var swapCmdTAndCmdN: Bool = SwapCmdTAndCmdNSetting.fallback
    /// `tabs.commandDigits`; workspaces when unset or invalid.
    public var commandDigits: CommandDigitsSetting = CommandDigitsSetting.fallback
    /// `palette.scopes.<scope>.prefix`: user-assigned palette scope prefixes.
    public var paletteScopePrefixes = PaletteScopePrefixes()
    /// `tasks.layout`; "inbox" when unset or invalid.
    public var tasksLayout: TasksLayoutPreference = TasksLayoutSetting().fallback
    /// `picker.pinned`: the cmux picker's pinned folders (absolute paths).
    public var pickerPinned: [String] = []
    /// `screenshots.*`: the Screenshots pane's app search and extra folders.
    public var screenshots = ScreenshotsSettings()
    /// `workspaces.autoArchive.*`: how idle workspaces archive (plans/cmux-next/auto-archive-DESIGN.md).
    public var autoArchive = AutoArchiveSettings()
    /// `workspaces.hibernation.*`: when idle workspaces leave memory (plans/cmux-next/workspace-hibernation-DESIGN.md).
    public var workspaceHibernation = WorkspaceHibernationSettings()
    /// `appearance.theme`: a Ghostty theme spec; nil (the Ghostty config's
    /// theme) when unset, empty or invalid.
    public var appTheme: String?
    /// `appearance.appTheme`: the theme cmux's own chrome and pages take their tokens from, apart
    /// from the terminal theme. Nil follows the terminal theme (`followTerminal`, the default).
    public var chromeTheme: String?
    /// `appearance.themeEdits`: per-token color edits to themes; none when unset.
    public var themeEdits = ThemeEdits.none
    /// `appearance.highlightColor`: the app's one highlight color (`#rrggbb`) over the terminal
    /// theme's `selection-background`; nil (the theme's) when unset or invalid.
    public var highlightColor: String?
    /// `appearance.accent`: where the chrome's accent comes from; neutral when unset or invalid.
    public var accent: ThemeAccent = AccentSetting().fallback
    /// `terminal.fontFamily`; nil (the Ghostty config's font) when unset or invalid.
    public var terminalFontFamily: String?
    /// `terminal.fontSize` in points; nil (the Ghostty config's size) when unset or invalid.
    public var terminalFontSize: Double?
    /// `history.terminalCommands` (opt-in terminal command history).
    public var recordsTerminalCommands: Bool = TerminalCommandHistorySetting.fallback
    /// `navigation.historyScope`: what Back and Forward walk (`workspace`, `window`, `surface`).
    public var navigationHistoryScope: String = NavigationHistoryScopeSetting.fallback
    /// `navigation.history.scope`: what a Back/Forward step is (`workspaces`, `everything`).
    public var navigationHistorySteps: String = NavigationHistoryStepSetting.fallback
    /// `history.commandRetentionDays` (days each daemon keeps terminal commands).
    public var commandRetentionDays: Int = CmuxConfigSnapshot.commandRetentionFallback
    /// The rest of `notifications.*`: dismissal, banners, sounds, quiet hours, mutes.
    public var notifications = NotificationPreferences()
    /// `updates.*`: automatic update behavior (R114).
    public var updates = UpdatesSettings()
    /// `computerUse.*`: whether cmux starts the signed Computer Use helper.
    public var computerUse = ComputerUseSettings()
    /// `freeModel.*`: the free AI model while signed out (cx-ds09i).
    public var freeModel = FreeModelSettings()
    /// `sessions.*`: what this Mac does while agents work (keep awake).
    public var sessions = SessionSettings()
    /// `agents.subsessions.*`: sub-session limits; the acpmux daemon enforces them.
    public var subsessions = SubsessionSettings()
    /// `agents.trust.*`: which folders start an agent without the trust question; the acpmux daemon reads the same file.
    public var trust = TrustSettings()
    /// `mobile.*`: whether the app runs its iPhone host.
    public var mobile = MobileSettings()
    /// `macScreen.*`: Mac Screen tabs (system shortcuts to the remote Mac).
    public var macScreen = MacScreenSettings()
    /// `macScreen.debug.*`: the Development section's Mac Screen switches (DEV builds read them).
    public var macScreenDebug = MacScreenDebugSettings()
    /// `deviceHub.*`: the Development section's device hub address (DEV builds read it).
    public var deviceHub = DeviceHubSettings()
    /// `announcements.*`: the cmux announcement cards (R114).
    public var announcements = AnnouncementsSettings()
    /// `feed.github`: this Mac's opt-in GitHub inbox connection.
    public var feedGitHub = FeedGitHubSettings()
    public var diagnostics: [SettingsDiagnostic]
    /// Retired keys the file still sets (`SettingsSchema.retiredKeys`):
    /// dropped without a diagnostic, listed for tooling.
    public var retiredKeys: [String] = []

    public static let empty = CmuxConfigSnapshot(root: .object([:]), density: nil, metrics: [:], shortcuts: [:], diagnostics: [])

    /// Parses a document. `validDensities` and `validMetrics` come from the
    /// design module so this stays free of main-actor types.
    public static func parse(
        _ root: JSONValue,
        validDensities: Set<String>,
        validMetrics: Set<String>,
        configDirectory: URL = CmuxConfigFile.defaultURL().deletingLastPathComponent()
    ) -> CmuxConfigSnapshot {
        var snapshot = CmuxConfigSnapshot(root: root, density: nil, metrics: [:], shortcuts: [:], diagnostics: [])
        guard case .object = root else {
            snapshot.diagnostics.append(SettingsDiagnostic(kind: .unreadableFile, path: "", message: "root is not an object"))
            return snapshot
        }
        snapshot.retiredKeys = SettingsSchema.retiredKeys.keys.filter { root.value(at: $0.split(separator: ".").map(String.init)) != nil }.sorted()
        snapshot.diagnostics += Self.chatDiagnostics(root)
        let tabBar = SurfaceTabBarParser.parse(root, configDirectory: configDirectory)
        snapshot.tabBar = tabBar.tabBar
        snapshot.commandActions = tabBar.actions
        snapshot.diagnostics += tabBar.diagnostics
        let (hints, hintsDiagnostic) = ModifierHoldHintsSetting().parse(root)
        snapshot.showModifierHoldHints = hints
        if let hintsDiagnostic { snapshot.diagnostics.append(hintsDiagnostic) }
        snapshot.take(BrowserDefaultEngine.parse(root), \.browserDefaultEngine)
        snapshot.take(BrowserSiteEngines.parse(root), \.browserSiteEngines)
        snapshot.take(BrowserNewTabPage.parse(root), \.browserNewTabPage)
        snapshot.take(BookmarksBarSetting.parse(root), \.browserShowBookmarksBar)
        snapshot.take(BrowserImportSetting.parse(root), \.browserImportEnabled)
        snapshot.take(BrowserCookieBannerSetting().parse(root), \.browserImportCookieBanner)
        snapshot.take(HomeChiefBubbleStyleSetting.parse(root), \.homeChiefBubbleStyle)
        snapshot.take(BuiltInAdBlockerSetting().parse(root), \.browserBuiltInAdBlocker)
        snapshot.take(AgentCursorSetting().parse(root), \.browserShowAgentCursor)
        snapshot.take(AgentMouseSetting().parse(root), \.browserAgentMouse)
        snapshot.takeHome(root)
        snapshot.take(Self.parsePreviewFeatures(root), \.previewFeatures)
        snapshot.take(Self.parseLabsToggle(root, path: classicHomePath, fallback: classicHomeDefault), \.classicHome)
        snapshot.take(Self.parseLabsToggle(root, path: voiceRoomPath, fallback: voiceRoomDefault), \.voiceRoom)
        snapshot.take(Self.parseLabsText(root, path: voiceRoomURLPath, fallback: voiceRoomURLDefault), \.voiceRoomURL)
        snapshot.take(Self.parseLabsToggle(root, path: machineJoinPath, fallback: machineJoinDefault), \.machineJoin)
        snapshot.take(BrowserHibernationSetting.parse(root), \.browserHibernation)
        snapshot.take(BrowserLinkClickSetting.parse(root), \.browserLinkClicks)
        snapshot.take(LinkRouting.parse(root), \.linkRouting)
        snapshot.take(TerminalLinkOpener.parse(root), \.terminalLinkOpener)
        snapshot.take(TextEditorSetting.parse(root), \.textEditor)
        snapshot.take(RemoteLocalhostSetting.parse(root), \.remoteLocalhost)
        let paneChrome = PaneChromeConfigParser.parse(root)
        snapshot.paneChrome = paneChrome.overrides
        snapshot.diagnostics += paneChrome.diagnostics
        let (speed, speedDiagnostic) = AnimationSpeedSetting.parse(root)
        snapshot.animationSpeed = speed
        if let speedDiagnostic { snapshot.diagnostics.append(speedDiagnostic) }
        snapshot.take(AnimationKindsSetting.parse(root), \.animationKinds)
        snapshot.take(MotionCategoriesSetting.parse(root), \.motionCategories)
        snapshot.take(PaneAnimationsSetting.parse(root), \.paneAnimations)
        snapshot.take(CalmModeSetting.parse(root), \.calmMode)
        let (centering, centeringDiagnostic) = CenterFocusedColumnSetting.parse(root)
        snapshot.centerFocusedColumn = centering
        if let centeringDiagnostic { snapshot.diagnostics.append(centeringDiagnostic) }
        snapshot.take(StripScrollbarSetting.parse(root), \.stripScrollbar)
        snapshot.take(CloseFocusSetting.parse(root), \.closeFocus)
        snapshot.defaultColumnWidth = DefaultColumnWidthSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.sidebarSections = SidebarSectionsSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.hoverCards = HoverCardSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.workspaceGroups = WorkspaceGroupConfig.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.nowPlaying = NowPlayingSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.colorTransition = ColorTransitionSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.chromeStyle = ChromeStyleSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.sidebarBorder = SidebarBorderSetting.parse(root, defaultShows: snapshot.chromeStyle.sidebarBorder ?? false,
                                                            diagnostics: &snapshot.diagnostics)
        ColumnLayoutSettings.parse(root, into: &snapshot)
        CmuxConfigSnapshot.parsePanePlacement(root, into: &snapshot)
        CmuxConfigSnapshot.parseWorkspaceList(root, into: &snapshot)
        snapshot.focusRing = PaneRingConfigParser.focusRing(root, diagnostics: &snapshot.diagnostics)
        snapshot.attention = PaneRingConfigParser.attention(root, diagnostics: &snapshot.diagnostics)
        snapshot.windowBackground = WindowBackgroundSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.inactiveWindowDim = WindowBackgroundSetting.parseInactiveDim(root, diagnostics: &snapshot.diagnostics)
        snapshot.wallpaperTint = WallpaperTintSetting().parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.surfaceBackgrounds = SurfaceBackgroundSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.backdropSelection = BackdropSelectionSetting().parse(root, diagnostics: &snapshot.diagnostics)
        if case .art(let art) = snapshot.backdropSelection { snapshot.backdropArt = art } else { snapshot.backdropArt = nil }
        snapshot.take(ReducedBackgroundsSetting.parse(root), \.reducedBackgrounds)
        snapshot.experimentalAppearance = ExperimentalAppearanceSetting().parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.appearanceTuning = AppearanceTuningSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.statusIndicator = StatusIndicatorConfigParser.parse(root, diagnostics: &snapshot.diagnostics)
        DiffViewerSetting.parse(root, diagnostics: &snapshot.diagnostics)
        ChatSettings.validate(root, diagnostics: &snapshot.diagnostics)
        CmuxConfigSnapshot.parseBrowser(root, into: &snapshot)
        CmuxConfigSnapshot.parseAgentPane(root, into: &snapshot)
        snapshot.agentPaneZoom = AgentPaneZoomSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.statusBehavior = StatusIndicatorConfigParser.behavior(root, diagnostics: &snapshot.diagnostics)
        let (borders, bordersDiagnostic) = BordersSetting.parse(root)
        snapshot.borders = borders
        if let bordersDiagnostic { snapshot.diagnostics.append(bordersDiagnostic) }
        let (indicator, indicatorDiagnostic) = PaneFocusSettings.parse(
            root, at: PaneFocusSettings.focusIndicatorPath, fallback: PaneFocusSettings.focusIndicatorFallback)
        snapshot.focusIndicator = indicator
        if let indicatorDiagnostic { snapshot.diagnostics.append(indicatorDiagnostic) }
        let (inactiveTabStyle, inactiveTabDiagnostic) = PaneFocusSettings.parse(
            root, at: PaneFocusSettings.inactiveTabStylePath, fallback: PaneFocusSettings.inactiveTabStyleFallback)
        snapshot.inactiveTabStyle = inactiveTabStyle
        if let inactiveTabDiagnostic { snapshot.diagnostics.append(inactiveTabDiagnostic) }
        let (titlebar, titlebarDiagnostic) = WindowTitlebarSetting.parse(root)
        snapshot.titlebar = titlebar
        if let titlebarDiagnostic { snapshot.diagnostics.append(titlebarDiagnostic) }
        let (titlebarButtons, titlebarButtonsDiagnostic) = TitlebarButtonsSetting.parse(root)
        snapshot.titlebarButtons = titlebarButtons
        if let titlebarButtonsDiagnostic { snapshot.diagnostics.append(titlebarButtonsDiagnostic) }
        let (plusButton, plusButtonDiagnostic) = PlusButtonSetting.parse(root)
        snapshot.plusButton = plusButton
        if let plusButtonDiagnostic { snapshot.diagnostics.append(plusButtonDiagnostic) }
        ChromePlacementSetting.parse(root, into: &snapshot)
        let (paneBackgrounds, paneBackgroundsDiagnostic) = PaneBackgroundsSetting.parse(root)
        snapshot.paneBackgrounds = paneBackgrounds
        if let paneBackgroundsDiagnostic { snapshot.diagnostics.append(paneBackgroundsDiagnostic) }
        let (quitBehavior, quitDiagnostic) = QuitBehaviorSetting.parse(root)
        snapshot.quitBehavior = quitBehavior
        if let quitDiagnostic { snapshot.diagnostics.append(quitDiagnostic) }
        snapshot.diagnostics += Self.closeWarningDiagnostics(root) + Self.hideDockIconWithoutWindowsDiagnostics(root) + Self.showMenuBarIconDiagnostics(root)
            + MachineColorsSetting().parse(root).1
        snapshot.diagnostics += Self.globalHotKeyDiagnostics(root) + Self.startAgentGlobalHotKeyDiagnostics(root) + AgentPaneReplySetting.parse(root).1
        snapshot.diagnostics += [NewTabTemplate.parse(root).1, NewTabPosition.parse(root).1].compactMap(\.self) + NewTabWidgetSettings.diagnostics(root)
        let (newTerminalOpensWorkspace, newTerminalOpensWorkspaceDiagnostic) = NewTerminalWorkspaceSetting.parse(root)
        snapshot.newTerminalOpensWorkspace = newTerminalOpensWorkspace
        if let newTerminalOpensWorkspaceDiagnostic { snapshot.diagnostics.append(newTerminalOpensWorkspaceDiagnostic) }
        let (cmdWClosesPinnedTabs, cmdWClosesPinnedTabsDiagnostic) = CmdWClosesPinnedTabsSetting.parse(root)
        snapshot.cmdWClosesPinnedTabs = cmdWClosesPinnedTabs
        if let cmdWClosesPinnedTabsDiagnostic { snapshot.diagnostics.append(cmdWClosesPinnedTabsDiagnostic) }
        snapshot.take(NativeNewTabPageSetting.parse(root), \.nativeNewTabPage)
        snapshot.take(TabOverflowSetting.parse(root), \.tabOverflow)
        let (swapCmdTAndCmdN, swapCmdTAndCmdNDiagnostic) = SwapCmdTAndCmdNSetting.parse(root)
        snapshot.swapCmdTAndCmdN = swapCmdTAndCmdN
        if let swapCmdTAndCmdNDiagnostic { snapshot.diagnostics.append(swapCmdTAndCmdNDiagnostic) }
        let (commandDigits, commandDigitsDiagnostic) = CommandDigitsSetting.parse(root)
        snapshot.commandDigits = commandDigits
        if let commandDigitsDiagnostic { snapshot.diagnostics.append(commandDigitsDiagnostic) }
        let (prefixes, prefixDiagnostics) = PaletteScopePrefixes.parse(root)
        snapshot.paletteScopePrefixes = prefixes
        snapshot.diagnostics += prefixDiagnostics
        let (pinned, pinnedDiagnostics) = PickerPinnedSetting.parse(root, home: NSHomeDirectory())
        snapshot.pickerPinned = pinned
        snapshot.diagnostics += pinnedDiagnostics
        snapshot.screenshots = ScreenshotsSettings.parse(root, home: NSHomeDirectory(), diagnostics: &snapshot.diagnostics)
        snapshot.autoArchive = AutoArchiveSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.workspaceHibernation = WorkspaceHibernationSettings.parse(root, diagnostics: &snapshot.diagnostics)
        let (tasksLayout, tasksLayoutDiagnostic) = TasksLayoutSetting().parse(root)
        snapshot.tasksLayout = tasksLayout
        if let tasksLayoutDiagnostic { snapshot.diagnostics.append(tasksLayoutDiagnostic) }
        snapshot.parseHistory(root)
        snapshot.parseNavigationHistory(root)
        snapshot.notifications = NotificationConfigParser.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.feedGitHub = FeedGitHubSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.updates = UpdatesSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.announcements = AnnouncementsSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.computerUse = ComputerUseSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.freeModel = FreeModelSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.sessions = SessionSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.subsessions = SubsessionSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.trust = TrustSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.mobile = MobileSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.macScreen = MacScreenSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.macScreenDebug = MacScreenDebugSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.deviceHub = DeviceHubSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.take(AppThemeSetting().parse(root), \.appTheme)
        snapshot.take(ChromeThemeSetting().parse(root), \.chromeTheme)
        snapshot.themeEdits = ThemeEditsSetting().parse(root, diagnostics: &snapshot.diagnostics)
        let (highlight, highlightDiagnostic) = HighlightColorSetting().parse(root)
        snapshot.highlightColor = highlight
        if let highlightDiagnostic { snapshot.diagnostics.append(highlightDiagnostic) }
        let (accent, accentDiagnostic) = AccentSetting().parse(root)
        snapshot.accent = accent
        if let accentDiagnostic { snapshot.diagnostics.append(accentDiagnostic) }
        let (fontFamily, fontFamilyDiagnostic) = TerminalFontSetting().parseFamily(root)
        snapshot.terminalFontFamily = fontFamily
        if let fontFamilyDiagnostic { snapshot.diagnostics.append(fontFamilyDiagnostic) }
        let (fontSize, fontSizeDiagnostic) = TerminalFontSetting().parseSize(root)
        snapshot.terminalFontSize = fontSize
        if let fontSizeDiagnostic { snapshot.diagnostics.append(fontSizeDiagnostic) }
        snapshot.uiScale = UIScaleSetting().parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.interfaceScale = InterfaceScaleSetting().parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.customDensities = CustomDensitiesSetting().parse(root, diagnostics: &snapshot.diagnostics)
        if let custom = root.value(at: CustomDensitySelectionSetting().configPath) {
            if let id = custom.stringValue, snapshot.customDensities.contains(where: { $0.id == id }) {
                snapshot.customDensity = id
            } else {
                snapshot.diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.customDensity",
                                                               message: "expected the id of one of appearance.customDensities"))
            }
        }
        if let appearance = root["appearance"] {
            if case .object(let members) = appearance {
                if let density = members["density"] {
                    if let value = density.stringValue, validDensities.contains(value) {
                        snapshot.density = value
                    } else {
                        snapshot.diagnostics.append(SettingsDiagnostic(
                            kind: .invalidValue, path: "appearance.density",
                            message: "expected one of \(validDensities.sorted().joined(separator: ", "))"
                        ))
                    }
                }
                if let metrics = members["metrics"] {
                    if case .object(let entries) = metrics {
                        for (name, value) in entries {
                            let path = "appearance.metrics.\(name)"
                            guard validMetrics.contains(name) else {
                                snapshot.diagnostics.append(SettingsDiagnostic(kind: .unknownMetric, path: path, message: "unknown metric"))
                                continue
                            }
                            guard let number = value.doubleValue else {
                                snapshot.diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected a number"))
                                continue
                            }
                            snapshot.metrics[name] = number
                            // The applier clamps; the diagnostic says so, as the Settings window refuses it.
                            if let range = LayoutMetricSetting.ranges[name], !range.contains(number) {
                                snapshot.diagnostics.append(SettingsDiagnostic(
                                    kind: .invalidValue, path: path,
                                    message: "expected a size in points from \(Int(range.lowerBound)) to \(Int(range.upperBound)); clamped"
                                ))
                            }
                        }
                    } else {
                        snapshot.diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.metrics", message: "expected an object"))
                    }
                }
            } else {
                snapshot.diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance", message: "expected an object"))
            }
        }

        if let shortcuts = root["shortcuts"] {
            guard case .object(let section) = shortcuts else {
                snapshot.diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "shortcuts", message: "expected an object"))
                return snapshot
            }
            var raw: [(String, String, JSONValue)] = []
            if let bindings = section["bindings"] {
                if case .object(let entries) = bindings {
                    raw += entries.map { ($0.key, "shortcuts.bindings.\($0.key)", $0.value) }
                } else {
                    snapshot.diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "shortcuts.bindings", message: "expected an object"))
                }
            }
            if let tiers = section["tiers"] {
                if case .object(let entries) = tiers {
                    for (id, value) in entries {
                        guard case .string(let tier) = value, ActionKeyTier(configValue: tier) != nil else {
                            snapshot.diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "shortcuts.tiers.\(id)",
                                                                           message: "expected \"system\", \"navigation\" or \"content\""))
                            continue
                        }
                        snapshot.keyTiers[id] = tier
                    }
                } else {
                    snapshot.diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "shortcuts.tiers", message: "expected an object"))
                }
            }
            raw += section.filter { !reservedShortcutKeys.contains($0.key) }.map { ($0.key, "shortcuts.\($0.key)", $0.value) }
            for (actionID, path, value) in raw {
                guard let binding = ShortcutBindingFormat.parse(value) else {
                    snapshot.diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "not a valid shortcut"))
                    continue
                }
                snapshot.shortcuts[actionID] = binding
            }
        }
        snapshot.diagnostics.sort { $0.path < $1.path }
        return snapshot
    }
}
