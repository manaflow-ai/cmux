/// `mobile.*` in cmux.json: phones reaching this Mac. `allowIPhoneConnections`
/// (off by default) lets the app run its cmux iPhone host while an
/// account is signed in, so the cmux app on the same account's iPhone
/// can open this Mac's workspaces, terminals and agent chats. Only the
/// person turns it on (agent policy `userOnly`).
///
/// `terminalSizing` and `terminalSizingOrder` are this Mac's terminal sizing
/// policy (cmux-next-ios/PROTOCOL.md "Terminal sizing policy"): which viewer's
/// size a terminal takes while this Mac and phones show it at once. The
/// cmux-tui daemon reads and applies them; the iPhone app writes them through
/// the daemon (`set-host-size-policy`), and this page shows the mode.
public nonisolated struct MobileSettings: Sendable, Equatable {
    public static let allowIPhoneConnectionsPath = ["mobile", "allowIPhoneConnections"]
    public static let terminalSizingPath = ["mobile", "terminalSizing"]
    public static let terminalSizingOrderPath = ["mobile", "terminalSizingOrder"]

    /// How a terminal shown on several devices is sized. The raw values are
    /// the daemon's (`mobile.terminalSizing`).
    public enum TerminalSizing: String, Sendable, CaseIterable {
        /// Every viewer sees the whole grid (the default).
        case smallest
        /// This Mac keeps its size; a phone pans or letterboxes.
        case mac
        /// The viewer that typed, pasted or focused last.
        case latest
        /// `terminalSizingOrder`, highest first.
        case priority
    }

    public var allowIPhoneConnections = false
    public var terminalSizing = TerminalSizing.smallest
    /// Device tokens, highest first: `mac` (this Mac's own views) or `device:<id>`.
    public var terminalSizingOrder: [String] = []

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["mobile"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("allowIPhoneConnections") { settings.allowIPhoneConnections = value }
        if let value = reader.choice("terminalSizing", TerminalSizing.self) { settings.terminalSizing = value }
        diagnostics = reader.diagnostics
        if case .array(let items) = root.value(at: terminalSizingOrderPath) {
            var seen = Set<String>()
            settings.terminalSizingOrder = items.compactMap(\.stringValue).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        return settings
    }
}

/// The Mobile settings rows (the Settings page's Mobile category).
nonisolated enum MobileSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.mobile", "iPhone")
        return [
            SettingDescriptor(
                MobileSettings.allowIPhoneConnectionsPath, section: .accounts, group: group,
                title: SettingsText.keyed("settings.mobile.allowIPhoneConnections", "Allow iPhone Connections"),
                help: SettingsText.keyed("settings.mobile.allowIPhoneConnections.help",
                                         "Lets the cmux app on your iPhone open this Mac's workspaces, terminals and agent chats while you are signed in with the same account."),
                summary: SettingsText.keyed("settings.mobile.allowIPhoneConnections.summary", "Lets your iPhone reach this Mac"),
                kind: .toggle, default: .bool(MobileSettings().allowIPhoneConnections),
                keywords: ["iphone", "phone", "mobile", "remote", "connect"]
            ),
            SettingDescriptor(
                MobileSettings.terminalSizingPath, section: .accounts, group: group,
                title: SettingsText.keyed("settings.mobile.terminalSizing", "Terminal Size When Shared"),
                help: SettingsText.keyed("settings.mobile.terminalSizing.help",
                                         "Decides the size of a terminal while this Mac and a phone show it at once. A device that gets a larger terminal than it fits scrolls sideways or shows empty space; text never wraps wrong. Set the priority order in the cmux app on your iPhone."),
                kind: .choice([
                    SettingChoice(MobileSettings.TerminalSizing.smallest.rawValue,
                                  SettingsText.keyed("settings.choice.terminalSizing.smallest", "Fit the Smallest Viewer")),
                    SettingChoice(MobileSettings.TerminalSizing.mac.rawValue,
                                  SettingsText.keyed("settings.choice.terminalSizing.mac", "Prefer This Mac")),
                    SettingChoice(MobileSettings.TerminalSizing.latest.rawValue,
                                  SettingsText.keyed("settings.choice.terminalSizing.latest", "Prefer the Active Device")),
                    SettingChoice(MobileSettings.TerminalSizing.priority.rawValue,
                                  SettingsText.keyed("settings.choice.terminalSizing.priority", "Priority Order")),
                ]),
                default: .string(MobileSettings().terminalSizing.rawValue),
                keywords: ["iphone", "phone", "mobile", "terminal", "size", "sizing", "shared", "priority", "columns"]
            ),
            SettingDescriptor(
                MobileSettings.terminalSizingOrderPath, section: .accounts, group: group,
                title: SettingsText.keyed("settings.mobile.terminalSizingOrder", "Terminal Size Priority"),
                help: SettingsText.keyed("settings.mobile.terminalSizingOrder.help",
                                         "The devices whose size a shared terminal takes first, highest first, when Terminal Size When Shared is Priority Order."),
                kind: .stringList, default: .array([]),
                keywords: ["iphone", "phone", "terminal", "size", "priority", "order"]
            )
            .hiddenFromSettingsPage("device ids, set in the cmux app on the iPhone"),
        ]
    }
}
