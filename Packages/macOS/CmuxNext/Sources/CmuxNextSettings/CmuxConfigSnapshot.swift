public import Foundation
import CmuxNextActions
public import CmuxNextDesign

/// A problem found while reading cmux.json. Loading never fails on a bad
/// entry: the entry is skipped and reported here.
public struct SettingsDiagnostic: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        /// The file is not valid JSONC. Nothing was applied from it.
        case unreadableFile
        case invalidValue
        case unknownAction
        case unknownMetric
        /// A chord whose first key has neither Command nor Control.
        case unsupportedChord
        /// Two actions claim the same shortcut in the same context.
        case shortcutConflict
        /// The file sets a key an MDM profile or the team policy manages; the file's value is ignored.
        case managedOverride
        /// An MDM forced value and the team policy's enforced value differ; the MDM value applies (decision E2).
        case managedConflict
    }

    public let kind: Kind
    /// Dotted key path of the offending entry.
    public let path: String
    public let message: String

    public init(kind: Kind, path: String, message: String) {
        self.kind = kind
        self.path = path
        self.message = message
    }

    public var description: String { "\(kind.rawValue) \(path): \(message)" }
}

/// The parts of cmux.json that cmux-next applies, parsed off the main actor.
/// Keys stay strings here; `SettingsApplier` maps them onto `DesignSettings`
/// and the action registry on the main actor.
public struct CmuxConfigSnapshot: Sendable, Equatable {
    /// The whole document, for `settings.get`.
    public var root: JSONValue
    /// `appearance.density`, when present and valid.
    public var density: String?
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
    /// `browser.newTabPage`; nil opens a blank page.
    public var browserNewTabPage: URL?
    /// `browser.showBookmarksBar`; off when unset.
    public var browserShowBookmarksBar = false
    /// `home.attachments.keepLocation`; off (strip location) when unset.
    public var homeKeepLocation = false
    /// `labs.previewFeatures`; off when unset.
    public var previewFeatures = false
    /// `browser.hibernation`, `browser.hibernationExclusions`, `browser.hibernatePinnedTabs`.
    public var browserHibernation: BrowserHibernationSetting = .fallback
    /// `browser.links.*`: what modified link clicks do; Chrome's when unset.
    public var browserLinkClicks: BrowserLinkClickSetting = .fallback
    /// `browser.searchEngine`, `browser.customSearchEngine.*`, `browser.omnibar.*`.
    public var browserOmnibar = BrowserOmnibarSetting.fallback
    /// `browser.remoteLocalhost` and `browser.remoteLocalhostWorkspaces`.
    public var remoteLocalhost: RemoteLocalhostSetting = .fallback
    /// `ui.animationSpeed`; "fast" when unset or invalid.
    public var animationSpeed: MotionSpeed = AnimationSpeedSetting.fallback
    /// `layout.centerFocusedColumn`; "never" when unset or invalid.
    public var centerFocusedColumn: CenterFocusedColumn = CenterFocusedColumnSetting.fallback
    /// `layout.stripScrollbar`; "auto" when unset or invalid.
    public var stripScrollbar: StripScrollbarMode = StripScrollbarSetting.fallback
    /// `sidebar.*` section settings; defaults when unset or invalid.
    public var sidebarSections = SidebarSectionsPreferences.defaults
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
    public var minimumPaneContentSize = CGSize(width: ColumnLayoutSettings.minimumPaneWidthFallback,
                                               height: ColumnLayoutSettings.minimumPaneHeightFallback)
    /// `layout.closeFocus`; "previousNeighbor" when unset or invalid.
    public var closeFocus: CloseFocusPolicy = CloseFocusSetting.fallback
    /// `layout.defaultColumnWidth`; 0.5 when unset or invalid.
    public var defaultColumnWidth: Double = DefaultColumnWidthSetting.fallback
    /// `focusRing.*`.
    public var focusRing = FocusRingSettings()
    /// `sidebar.border` and `sidebar.borderWidth`.
    public var sidebarBorder = SidebarBorder()
    /// `notifications.attention.*`.
    public var attention = AttentionSettings()
    /// `appearance.backgroundOpacity` and `appearance.backgroundBlur`; both nil (Ghostty's values) when unset or invalid.
    public var windowBackground = WindowBackgroundOverride()
    /// `appearance.surfaces.<surface>.color|opacity` (R55); no override
    /// (every surface shows the window's backdrop) when unset or invalid.
    public var surfaceBackgrounds = SurfaceBackgrounds.none
    /// `appearance.backdropArt`; nil disables the bundled painting.
    public var backdropArt: BackdropArt?
    /// `appearance.background`; nil leaves the desktop untouched.
    public var backdropSelection: BackdropSelection?
    /// `appearance.experimentalControls`; off unless explicitly enabled.
    public var experimentalAppearance = false
    /// `appearance.glassTransparency`, `appearance.hue` and
    /// `appearance.saturation`; identity values when unset or invalid.
    public var appearanceTuning = AppearanceTuningSetting.fallback
    /// `appearance.statusIndicator.*`.
    public var statusIndicator = StatusIndicatorSettings()
    /// `status.*`.
    public var statusBehavior = StatusBehaviorSettings()
    /// `appearance.borders`; "default" when unset or invalid.
    public var borders: BorderMode = BordersSetting.fallback
    /// `appearance.focusIndicator`; "both" when unset or invalid.
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
    /// `tabs.barPosition` (R109).
    public var tabBarPosition: TabBarPosition = .top
    /// `tabs.barOrder` (R109).
    public var tabBarOrder: TabBarOrder = .aboveToolbar
    /// `app.quitBehavior`; "ask" when unset or invalid.
    public var quitBehavior: QuitBehavior = QuitBehaviorSetting.fallback
    /// `tabs.newTabKind`; "same-kind" when unset or invalid.
    public var newTabKind: NewTabDefaultKind = NewTabDefaultKind.fallback
    /// `newTerminal.opensWorkspace`; off when unset or invalid.
    public var newTerminalOpensWorkspace: Bool = NewTerminalWorkspaceSetting.fallback
    /// `palette.scopes.<scope>.prefix`: user-assigned palette scope prefixes.
    public var paletteScopePrefixes = PaletteScopePrefixes()
    /// `tasks.layout`; "inbox" when unset or invalid.
    public var tasksLayout: TasksLayoutPreference = TasksLayoutSetting().fallback
    /// `picker.pinned`: the cmux picker's pinned folders (absolute paths).
    public var pickerPinned: [String] = []
    /// `appearance.theme`: a Ghostty theme spec; nil (the Ghostty config's
    /// theme) when unset, empty or invalid.
    public var appTheme: String?
    /// `terminal.fontFamily`; nil (the Ghostty config's font) when unset or invalid.
    public var terminalFontFamily: String?
    /// `terminal.fontSize` in points; nil (the Ghostty config's size) when unset or invalid.
    public var terminalFontSize: Double?
    /// `history.terminalCommands` (opt-in terminal command history).
    public var recordsTerminalCommands: Bool = TerminalCommandHistorySetting.fallback
    /// `navigation.historyScope`: what Back and Forward walk (`workspace`, `window`, `surface`).
    public var navigationHistoryScope: String = NavigationHistoryScopeSetting.fallback
    /// The rest of `notifications.*`: dismissal, banners, sounds, quiet hours, mutes.
    public var notifications = NotificationPreferences()
    /// `updates.*`: automatic update behavior (R114).
    public var updates = UpdatesSettings()
    /// `announcements.*`: the cmux announcement cards (R114).
    public var announcements = AnnouncementsSettings()
    /// `feed.github`: this Mac's opt-in GitHub inbox connection.
    public var feedGitHub = FeedGitHubSettings()
    public var diagnostics: [SettingsDiagnostic]
    /// Retired keys the file still sets (`SettingsSchema.retiredKeys`):
    /// dropped without a diagnostic, listed for tooling.
    public var retiredKeys: [String] = []

    public static let empty = CmuxConfigSnapshot(root: .object([:]), density: nil, metrics: [:], shortcuts: [:], diagnostics: [])

    /// Keys under `shortcuts` that are settings, not action IDs.
    static let reservedShortcutKeys: Set<String> = ["bindings", "tiers", "when", "showModifierHoldHints"]

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
        let tabBar = SurfaceTabBarParser.parse(root, configDirectory: configDirectory)
        snapshot.tabBar = tabBar.tabBar
        snapshot.commandActions = tabBar.actions
        snapshot.diagnostics += tabBar.diagnostics
        let (hints, hintsDiagnostic) = ModifierHoldHintsSetting().parse(root)
        snapshot.showModifierHoldHints = hints
        if let hintsDiagnostic { snapshot.diagnostics.append(hintsDiagnostic) }
        let (engine, engineDiagnostic) = BrowserDefaultEngine.parse(root)
        snapshot.browserDefaultEngine = engine
        if let engineDiagnostic { snapshot.diagnostics.append(engineDiagnostic) }
        let (newTabPage, newTabPageDiagnostic) = BrowserNewTabPage.parse(root)
        snapshot.browserNewTabPage = newTabPage
        if let newTabPageDiagnostic { snapshot.diagnostics.append(newTabPageDiagnostic) }
        snapshot.take(BookmarksBarSetting.parse(root), \.browserShowBookmarksBar)
        snapshot.take(HomeKeepLocationSetting.parse(root), \.homeKeepLocation)
        snapshot.take(Self.parsePreviewFeatures(root), \.previewFeatures)
        let (hibernation, hibernationDiagnostics) = BrowserHibernationSetting.parse(root)
        snapshot.browserHibernation = hibernation
        snapshot.diagnostics += hibernationDiagnostics
        let (linkClicks, linkClickDiagnostics) = BrowserLinkClickSetting.parse(root)
        snapshot.browserLinkClicks = linkClicks
        snapshot.diagnostics += linkClickDiagnostics
        let (remoteLocalhost, remoteLocalhostDiagnostics) = RemoteLocalhostSetting.parse(root)
        snapshot.remoteLocalhost = remoteLocalhost
        snapshot.diagnostics += remoteLocalhostDiagnostics
        let paneChrome = PaneChromeConfigParser.parse(root)
        snapshot.paneChrome = paneChrome.overrides
        snapshot.diagnostics += paneChrome.diagnostics
        let (speed, speedDiagnostic) = AnimationSpeedSetting.parse(root)
        snapshot.animationSpeed = speed
        if let speedDiagnostic { snapshot.diagnostics.append(speedDiagnostic) }
        let (centering, centeringDiagnostic) = CenterFocusedColumnSetting.parse(root)
        snapshot.centerFocusedColumn = centering
        if let centeringDiagnostic { snapshot.diagnostics.append(centeringDiagnostic) }
        let (scrollbar, scrollbarDiagnostic) = StripScrollbarSetting.parse(root)
        snapshot.stripScrollbar = scrollbar
        if let scrollbarDiagnostic { snapshot.diagnostics.append(scrollbarDiagnostic) }
        let (closeFocus, closeFocusDiagnostic) = CloseFocusSetting.parse(root)
        snapshot.closeFocus = closeFocus
        if let closeFocusDiagnostic { snapshot.diagnostics.append(closeFocusDiagnostic) }
        snapshot.defaultColumnWidth = DefaultColumnWidthSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.sidebarSections = SidebarSectionsSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.sidebarBorder = SidebarBorderSetting.parse(root, diagnostics: &snapshot.diagnostics)
        ColumnLayoutSettings.parse(root, into: &snapshot)
        snapshot.focusRing = PaneRingConfigParser.focusRing(root, diagnostics: &snapshot.diagnostics)
        snapshot.attention = PaneRingConfigParser.attention(root, diagnostics: &snapshot.diagnostics)
        snapshot.windowBackground = WindowBackgroundSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.surfaceBackgrounds = SurfaceBackgroundSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.backdropSelection = BackdropSelectionSetting().parse(root, diagnostics: &snapshot.diagnostics)
        if case .art(let art) = snapshot.backdropSelection { snapshot.backdropArt = art }
        snapshot.experimentalAppearance = ExperimentalAppearanceSetting().parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.appearanceTuning = AppearanceTuningSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.statusIndicator = StatusIndicatorConfigParser.parse(root, diagnostics: &snapshot.diagnostics)
        DiffViewerSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.browserOmnibar = BrowserOmnibarSetting.parse(root, diagnostics: &snapshot.diagnostics)
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
        let (quitBehavior, quitDiagnostic) = QuitBehaviorSetting.parse(root)
        snapshot.quitBehavior = quitBehavior
        if let quitDiagnostic { snapshot.diagnostics.append(quitDiagnostic) }
        snapshot.diagnostics += Self.closeWarningDiagnostics(root)
        let (newTabKind, newTabKindDiagnostic) = NewTabDefaultKind.parse(root)
        snapshot.newTabKind = newTabKind
        if let newTabKindDiagnostic { snapshot.diagnostics.append(newTabKindDiagnostic) }
        let (newTerminalOpensWorkspace, newTerminalOpensWorkspaceDiagnostic) = NewTerminalWorkspaceSetting.parse(root)
        snapshot.newTerminalOpensWorkspace = newTerminalOpensWorkspace
        if let newTerminalOpensWorkspaceDiagnostic { snapshot.diagnostics.append(newTerminalOpensWorkspaceDiagnostic) }
        let (prefixes, prefixDiagnostics) = PaletteScopePrefixes.parse(root)
        snapshot.paletteScopePrefixes = prefixes
        snapshot.diagnostics += prefixDiagnostics
        let (pinned, pinnedDiagnostics) = PickerPinnedSetting.parse(root, home: NSHomeDirectory())
        snapshot.pickerPinned = pinned
        snapshot.diagnostics += pinnedDiagnostics
        let (tasksLayout, tasksLayoutDiagnostic) = TasksLayoutSetting().parse(root)
        snapshot.tasksLayout = tasksLayout
        if let tasksLayoutDiagnostic { snapshot.diagnostics.append(tasksLayoutDiagnostic) }
        let (recordsCommands, commandsDiagnostic) = TerminalCommandHistorySetting.parse(root)
        snapshot.recordsTerminalCommands = recordsCommands
        if let commandsDiagnostic { snapshot.diagnostics.append(commandsDiagnostic) }
        let (historyScope, historyScopeDiagnostic) = NavigationHistoryScopeSetting.parse(root)
        snapshot.navigationHistoryScope = historyScope
        if let historyScopeDiagnostic { snapshot.diagnostics.append(historyScopeDiagnostic) }
        snapshot.notifications = NotificationConfigParser.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.feedGitHub = FeedGitHubSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.updates = UpdatesSettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.announcements = AnnouncementsSettings.parse(root, diagnostics: &snapshot.diagnostics)
        let (appTheme, appThemeDiagnostic) = AppThemeSetting().parse(root)
        snapshot.appTheme = appTheme
        if let appThemeDiagnostic { snapshot.diagnostics.append(appThemeDiagnostic) }
        let (fontFamily, fontFamilyDiagnostic) = TerminalFontSetting().parseFamily(root)
        snapshot.terminalFontFamily = fontFamily
        if let fontFamilyDiagnostic { snapshot.diagnostics.append(fontFamilyDiagnostic) }
        let (fontSize, fontSizeDiagnostic) = TerminalFontSetting().parseSize(root)
        snapshot.terminalFontSize = fontSize
        if let fontSizeDiagnostic { snapshot.diagnostics.append(fontSizeDiagnostic) }

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
