public import CmuxNextDesign

/// One row of a list section (a room, a machine).
public struct SettingsListRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    /// An emoji or an SF Symbol (``IconValue``; assets draw as a symbol for now).
    public let icon: IconValue
    /// The current room, or a connected machine.
    public let isActive: Bool

    public init(id: String, title: String, subtitle: String? = nil, icon: IconValue, isActive: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.isActive = isActive
    }

    public init(id: String, title: String, subtitle: String? = nil, symbol: String, isActive: Bool = false) {
        self.init(id: id, title: title, subtitle: subtitle, icon: .symbol(symbol), isActive: isActive)
    }

    /// A space's row: its own icon (emoji or symbol), else the space symbol.
    public static func space(id: String, title: String, icon: String?, isActive: Bool = false) -> SettingsListRow {
        SettingsListRow(id: id, title: title, icon: IconValue(wire: icon) ?? .symbol("square.stack"), isActive: isActive)
    }

    /// A machine's row: its own icon (`session-icon-v1`: an emoji, a symbol or a
    /// stored asset the page draws as an image), else `symbol`, its kind's.
    public static func machine(id: String, title: String, subtitle: String? = nil, icon: String?, symbol: String,
                               isActive: Bool = false) -> SettingsListRow {
        SettingsListRow(id: id, title: title, subtitle: subtitle, icon: IconValue(wire: icon) ?? .symbol(symbol), isActive: isActive)
    }
}
