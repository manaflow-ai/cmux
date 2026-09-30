public import CmuxNextActions

/// What the Settings window needs from the App that cmux.json does not hold:
/// live rooms and machines (daemon state), the Ghostty config and shell
/// integration, and the shortcut writer. Reads happen in SwiftUI bodies, so
/// an observable App store behind them updates the window.
@MainActor public protocol SettingsWindowHost: AnyObject {
    /// Rooms of the local daemon; nil when it has no rooms (older daemon),
    /// so the section shows a placeholder.
    var rooms: [SettingsListRow]? { get }
    /// Saved SSH machines and Cloud machines.
    var machines: [SettingsListRow] { get }
    /// Path of the Ghostty config cmux reads.
    var ghosttyConfigPath: String { get }
    /// How shell integration runs, for the Terminal section (nil: unknown).
    var shellIntegration: String? { get }
    /// Writes recorded shortcuts to cmux.json (the palette's writer).
    var shortcutEditor: (any ShortcutRecorderEditing)? { get }
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
    public var rooms: [SettingsListRow]? = [
        SettingsListRow(id: "default", title: "Personal", subtitle: "3 workspaces", symbol: "person", isActive: true),
        SettingsListRow(id: "work", title: "Work", subtitle: "5 workspaces", symbol: "briefcase"),
    ]
    public var machines: [SettingsListRow] = [
        SettingsListRow(id: "ssh:devbox", title: "devbox", subtitle: "lawrence@devbox", symbol: "server.rack", isActive: true),
    ]
    public var ghosttyConfigPath = "~/.config/ghostty/config"
    public var shellIntegration: String? = "zsh"
    public weak var shortcutEditor: (any ShortcutRecorderEditing)?

    public init() {}
}
