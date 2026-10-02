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
    /// `browser.hibernation`, `browser.hibernationExclusions`, `browser.hibernatePinnedTabs`.
    public var browserHibernation: BrowserHibernationSetting = .fallback
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
    /// `layout.splitSizing`, `layout.newColumnWidth`, sticky defaults and the
    /// minimum pane size (`ColumnLayoutSettings`).
    public var splitSizing: SplitSizing = ColumnLayoutSettings.splitSizingFallback
    public var newColumnWidth: NewColumnWidthMode = ColumnLayoutSettings.newColumnWidthFallback
    public var stickyColumnEdge: StickyDefaultEdge = ColumnLayoutSettings.stickyEdgeFallback
    public var stickyColumnMode: StickyDefaultMode = ColumnLayoutSettings.stickyModeFallback
    /// `layout.frameOrientation`: which docks own the frame's corners.
    public var frameOrientation: FrameOrientation = ColumnLayoutSettings.frameOrientationFallback
    public var minimumPaneContentSize = CGSize(width: ColumnLayoutSettings.minimumPaneWidthFallback,
                                               height: ColumnLayoutSettings.minimumPaneHeightFallback)
    /// `layout.closeFocus`; "previousNeighbor" when unset or invalid.
    public var closeFocus: CloseFocusPolicy = CloseFocusSetting.fallback
    /// `layout.defaultColumnWidth`; 0.5 when unset or invalid.
    public var defaultColumnWidth: Double = DefaultColumnWidthSetting.fallback
    /// `focusRing.*`.
    public var focusRing = FocusRingSettings()
    /// `notifications.attention.*`.
    public var attention = AttentionSettings()
    /// `appearance.backgroundOpacity` and `appearance.backgroundBlur`; both
    /// nil (Ghostty's values) when unset or invalid.
    public var windowBackground = WindowBackgroundOverride()
    /// `appearance.statusIndicator.*`.
    public var statusIndicator = StatusIndicatorSettings()
    /// `status.*`.
    public var statusBehavior = StatusBehaviorSettings()
    /// `appearance.borders`; "default" when unset or invalid.
    public var borders: BorderMode = BordersSetting.fallback
    /// `appearance.focusIndicator`; "both" when unset or invalid.
    public var focusIndicator: FocusIndicator = PaneFocusSettings.focusIndicatorFallback
    /// `appearance.tabBarBackground`; "window" when unset or invalid.
    public var tabBarBackground: TabBarBackground = PaneFocusSettings.tabBarBackgroundFallback
    /// `window.titlebar`; "minimal" when unset or invalid.
    public var titlebar: TitlebarStyle = WindowTitlebarSetting.fallback
    /// `window.rail`; "off" when unset or invalid.
    public var rail: WindowRailPlacement = WindowRailSetting.fallback
    /// `app.quitBehavior`; "ask" when unset or invalid.
    public var quitBehavior: QuitBehavior = QuitBehaviorSetting.fallback
    /// `tabs.newTabKind`; "same-kind" when unset or invalid.
    public var newTabKind: NewTabDefaultKind = NewTabKindSetting.fallback
    /// `appearance.theme`: a Ghostty theme spec; nil (the Ghostty config's
    /// theme) when unset, empty or invalid.
    public var appTheme: String?
    /// `terminal.fontFamily`; nil (the Ghostty config's font) when unset or invalid.
    public var terminalFontFamily: String?
    /// `terminal.fontSize` in points; nil (the Ghostty config's size) when unset or invalid.
    public var terminalFontSize: Double?
    /// `history.terminalCommands` (opt-in terminal command history).
    public var recordsTerminalCommands: Bool = TerminalCommandHistorySetting.fallback
    /// The rest of `notifications.*`: dismissal, banners, sounds, quiet hours, mutes.
    public var notifications = NotificationPreferences()
    public var diagnostics: [SettingsDiagnostic]

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
        let tabBar = SurfaceTabBarParser.parse(root, configDirectory: configDirectory)
        snapshot.tabBar = tabBar.tabBar
        snapshot.commandActions = tabBar.actions
        snapshot.diagnostics += tabBar.diagnostics
        let (engine, engineDiagnostic) = BrowserDefaultEngine.parse(root)
        snapshot.browserDefaultEngine = engine
        if let engineDiagnostic { snapshot.diagnostics.append(engineDiagnostic) }
        let (newTabPage, newTabPageDiagnostic) = BrowserNewTabPage.parse(root)
        snapshot.browserNewTabPage = newTabPage
        if let newTabPageDiagnostic { snapshot.diagnostics.append(newTabPageDiagnostic) }
        let (showBar, showBarDiagnostic) = BookmarksBarSetting.parse(root)
        snapshot.browserShowBookmarksBar = showBar
        if let showBarDiagnostic { snapshot.diagnostics.append(showBarDiagnostic) }
        let (hibernation, hibernationDiagnostics) = BrowserHibernationSetting.parse(root)
        snapshot.browserHibernation = hibernation
        snapshot.diagnostics += hibernationDiagnostics
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
        ColumnLayoutSettings.parse(root, into: &snapshot)
        snapshot.focusRing = PaneRingConfigParser.focusRing(root, diagnostics: &snapshot.diagnostics)
        snapshot.attention = PaneRingConfigParser.attention(root, diagnostics: &snapshot.diagnostics)
        snapshot.windowBackground = WindowBackgroundSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.statusIndicator = StatusIndicatorConfigParser.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.statusBehavior = StatusIndicatorConfigParser.behavior(root, diagnostics: &snapshot.diagnostics)
        let (borders, bordersDiagnostic) = BordersSetting.parse(root)
        snapshot.borders = borders
        if let bordersDiagnostic { snapshot.diagnostics.append(bordersDiagnostic) }
        let (indicator, indicatorDiagnostic) = PaneFocusSettings.parse(
            root, at: PaneFocusSettings.focusIndicatorPath, fallback: PaneFocusSettings.focusIndicatorFallback)
        snapshot.focusIndicator = indicator
        if let indicatorDiagnostic { snapshot.diagnostics.append(indicatorDiagnostic) }
        let (tabBarBackground, tabBarDiagnostic) = PaneFocusSettings.parse(
            root, at: PaneFocusSettings.tabBarBackgroundPath, fallback: PaneFocusSettings.tabBarBackgroundFallback)
        snapshot.tabBarBackground = tabBarBackground
        if let tabBarDiagnostic { snapshot.diagnostics.append(tabBarDiagnostic) }
        let (titlebar, titlebarDiagnostic) = WindowTitlebarSetting.parse(root)
        snapshot.titlebar = titlebar
        if let titlebarDiagnostic { snapshot.diagnostics.append(titlebarDiagnostic) }
        let (rail, railDiagnostic) = WindowRailSetting.parse(root)
        snapshot.rail = rail
        if let railDiagnostic { snapshot.diagnostics.append(railDiagnostic) }
        let (quitBehavior, quitDiagnostic) = QuitBehaviorSetting.parse(root)
        snapshot.quitBehavior = quitBehavior
        if let quitDiagnostic { snapshot.diagnostics.append(quitDiagnostic) }
        let (newTabKind, newTabKindDiagnostic) = NewTabKindSetting.parse(root)
        snapshot.newTabKind = newTabKind
        if let newTabKindDiagnostic { snapshot.diagnostics.append(newTabKindDiagnostic) }
        let (recordsCommands, commandsDiagnostic) = TerminalCommandHistorySetting.parse(root)
        snapshot.recordsTerminalCommands = recordsCommands
        if let commandsDiagnostic { snapshot.diagnostics.append(commandsDiagnostic) }
        snapshot.notifications = NotificationConfigParser.parse(root, diagnostics: &snapshot.diagnostics)
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
                            let interfaceSize = InterfaceSizeSetting()
                            if name == interfaceSize.metricName, !interfaceSize.range.contains(number) {
                                snapshot.diagnostics.append(SettingsDiagnostic(
                                    kind: .invalidValue, path: path,
                                    message: "expected a size in points from \(Int(interfaceSize.range.lowerBound)) to \(Int(interfaceSize.range.upperBound)); clamped"
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
