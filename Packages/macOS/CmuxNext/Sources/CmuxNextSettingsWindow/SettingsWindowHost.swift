public import CmuxNextActions
public import CmuxNextDesign
public import SwiftUI

/// What the Settings window needs from the App that cmux-next.json does not hold:
/// live rooms and machines (daemon state), the Ghostty config and shell
/// integration, and the shortcut writer. Reads happen in SwiftUI bodies, so
/// an observable App store behind them updates the window.
@MainActor public protocol SettingsWindowHost: AnyObject {
    /// Closes the focused Settings page tab when Escape is pressed outside
    /// shortcut recording. Window Settings uses the regular window close path.
    func closeSettingsPane()
    /// Rooms of the local daemon; nil when it has no rooms (older daemon),
    /// so the section shows a placeholder.
    var rooms: [SettingsListRow]? { get }
    /// Saved SSH machines and Cloud machines.
    var machines: [SettingsListRow] { get }
    /// Path of the Ghostty config cmux reads.
    var ghosttyConfigPath: String { get }
    /// How shell integration runs, for the Terminal section (nil: unknown).
    var shellIntegration: String? { get }
    /// Writes recorded shortcuts to cmux-next.json (the palette's writer).
    var shortcutEditor: (any ShortcutRecorderEditing)? { get }
    /// Browser profiles in order (edited through the registry's
    /// `browserProfile.*` actions, so every entrypoint shares one path).
    var browserProfiles: [SettingsBrowserProfileRow] { get }
    /// Theme picker (Appearance): the levels the window Settings was opened
    /// from can theme (empty hides the picker).
    var themeLevels: [SettingsThemeLevel] { get }
    /// Every Ghostty theme name.
    var themeNames: [String] { get }
    /// The theme set at `level` of that window; nil is the Ghostty config.
    func theme(at level: SettingsThemeLevel) -> String?
    /// Whether Ghostty accepts `text` as a theme (a name, a path, or a
    /// `light:A,dark:B` pair).
    func acceptsTheme(_ text: String) -> Bool
    /// Sets (nil: resets to the Ghostty config) the theme at `level`, through
    /// the same actions as the palette and menus.
    func setTheme(_ spec: String?, at level: SettingsThemeLevel)
    /// Accounts: provider sign-ins and CodeRouter accounts, drawn in the
    /// window's theme `tokens` (nil hides the section's content).
    func accountsView(tokens: ThemeTokens) -> AnyView?
    /// The value a number setting at `path` resolves to while cmux-next.json
    /// leaves it unset (the window opacity from the Ghostty config), shown
    /// by its slider; nil uses the descriptor's placeholder.
    func derivedNumber(at path: [String]) -> Double?
    /// Global actions whose shortcut could not be registered system-wide
    /// (another app or another global action holds the key), so it works
    /// only while cmux is in front.
    var systemWideRefusals: Set<ActionID> { get }
}

extension SettingsWindowHost {
    public func closeSettingsPane() {}
    public var themeLevels: [SettingsThemeLevel] { [] }
    public var themeNames: [String] { [] }
    public func theme(at level: SettingsThemeLevel) -> String? { nil }
    public func acceptsTheme(_ text: String) -> Bool { false }
    public func setTheme(_ spec: String?, at level: SettingsThemeLevel) {}
    public func accountsView(tokens: ThemeTokens) -> AnyView? { nil }
    public func derivedNumber(at path: [String]) -> Double? { nil }
    public var systemWideRefusals: Set<ActionID> { [] }
}

/// One row of a list section (a room, a machine).
public struct SettingsListRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let symbol: String
    /// The current room, or a connected machine.
    public let isActive: Bool

    public init(id: String, title: String, subtitle: String? = nil, symbol: String, isActive: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.isActive = isActive
    }
}

/// A host with sample data, for the demo and tests.
@MainActor public final class MockSettingsWindowHost: SettingsWindowHost {
    public private(set) var closeSettingsPaneCalls = 0
    public var rooms: [SettingsListRow]? = [
        SettingsListRow(id: "default", title: "Personal", subtitle: "3 workspaces", symbol: "person", isActive: true),
        SettingsListRow(id: "work", title: "Work", subtitle: "5 workspaces", symbol: "briefcase"),
    ]
    public var machines: [SettingsListRow] = [
        SettingsListRow(id: "ssh:devbox", title: "devbox", subtitle: "dev@devbox", symbol: "server.rack", isActive: true),
    ]
    public var ghosttyConfigPath = "~/.config/ghostty/config"
    public var shellIntegration: String? = "zsh"
    public weak var shortcutEditor: (any ShortcutRecorderEditing)?
    public var systemWideRefusals: Set<ActionID> = []
    public var browserProfiles: [SettingsBrowserProfileRow] = [
        SettingsBrowserProfileRow(id: "default", name: "Default", isDefault: true),
        SettingsBrowserProfileRow(id: "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", name: "Work", color: "green", icon: "💼",
                                  source: "Google Chrome · Work"),
    ]

    public init() {}

    public func closeSettingsPane() { closeSettingsPaneCalls += 1 }
}
