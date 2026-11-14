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
    public var allowIPhoneConnections = MobileSettings.allowIPhoneConnectionsDefault
    /// How a terminal shown on several devices is sized (`MobileTerminalSizing`).
    public var terminalSizing = MobileSettings.terminalSizingDefault
    /// Device tokens, highest first: `mac` (this Mac's own views) or `device:<id>`.
    public var terminalSizingOrder = MobileSettings.terminalSizingOrderDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["mobile"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("allowIPhoneConnections") { settings.allowIPhoneConnections = value }
        if let value = reader.choice("terminalSizing", MobileTerminalSizing.self) { settings.terminalSizing = value }
        diagnostics = reader.diagnostics
        if case .array(let items) = root.value(at: terminalSizingOrderPath) {
            var seen = Set<String>()
            settings.terminalSizingOrder = items.compactMap(\.stringValue).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        return settings
    }
}
