/// Local WebKit page residency. Defaults and ranges come from the shared
/// schemas/settings/source/chat-page-hibernation.json, also read by cmux-config.
public nonisolated struct ChatPageHibernationSettings: Sendable, Equatable {
    public var enabled: Bool
    public var hiddenMinutes: Double
    public var newTabCapacity: Int

    public init(enabled: Bool = Self.enabledDefault, hiddenMinutes: Double = Self.hiddenMinutesDefault,
                newTabCapacity: Int = Int(Self.newTabCapacityDefault)) {
        self.enabled = enabled
        self.hiddenMinutes = hiddenMinutes
        self.newTabCapacity = newTabCapacity
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        guard var reader = ConfigFieldReader(root, at: ["agents", "chatPages"], diagnostics: &diagnostics) else { return Self() }
        let enabled = reader.bool("enabled") ?? enabledDefault
        let minutes = reader.number("hiddenMinutes", range: hiddenMinutesRange) ?? hiddenMinutesDefault
        let capacity = reader.number("newTabCapacity", range: newTabCapacityRange) ?? newTabCapacityDefault
        diagnostics += reader.diagnostics
        return Self(enabled: enabled, hiddenMinutes: minutes, newTabCapacity: Int(capacity))
    }
}
