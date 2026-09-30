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
        /// A two-stroke chord; the registry cannot dispatch chords yet.
        case unsupportedChord
        /// Two actions claim the same shortcut in the same context.
        case shortcutConflict
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
    /// `browser.hibernation`, `browser.hibernationExclusions`, `browser.hibernatePinnedTabs`.
    public var browserHibernation: BrowserHibernationSetting = .fallback
    /// `browser.remoteLocalhost` and `browser.remoteLocalhostWorkspaces`.
    public var remoteLocalhost: RemoteLocalhostSetting = .fallback
    /// `ui.animationSpeed`; "fast" when unset or invalid.
    public var animationSpeed: MotionSpeed = AnimationSpeedSetting.fallback
    /// `layout.centerFocusedColumn`; "never" when unset or invalid.
    public var centerFocusedColumn: CenterFocusedColumn = CenterFocusedColumnSetting.fallback
    /// `layout.defaultColumnWidth`; 0.5 when unset or invalid.
    public var defaultColumnWidth: Double = DefaultColumnWidthSetting.fallback
    /// `focusRing.*`.
    public var focusRing = FocusRingSettings()
    /// `notifications.attention.*`.
    public var attention = AttentionSettings()
    /// `window.titlebar`; "minimal" when unset or invalid.
    public var titlebar: TitlebarStyle = WindowTitlebarSetting.fallback
    /// `app.quitBehavior`; "ask" when unset or invalid.
    public var quitBehavior: QuitBehavior = QuitBehaviorSetting.fallback
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
        snapshot.defaultColumnWidth = DefaultColumnWidthSetting.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.focusRing = PaneRingConfigParser.focusRing(root, diagnostics: &snapshot.diagnostics)
        snapshot.attention = PaneRingConfigParser.attention(root, diagnostics: &snapshot.diagnostics)
        let (titlebar, titlebarDiagnostic) = WindowTitlebarSetting.parse(root)
        snapshot.titlebar = titlebar
        if let titlebarDiagnostic { snapshot.diagnostics.append(titlebarDiagnostic) }
        let (quitBehavior, quitDiagnostic) = QuitBehaviorSetting.parse(root)
        snapshot.quitBehavior = quitBehavior
        if let quitDiagnostic { snapshot.diagnostics.append(quitDiagnostic) }
        snapshot.notifications = NotificationConfigParser.parse(root, diagnostics: &snapshot.diagnostics)

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
