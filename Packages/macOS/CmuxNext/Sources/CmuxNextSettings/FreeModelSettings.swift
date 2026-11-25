/// `freeModel.*` in cmux.json (cx-ds09i): `enabled` (on by default) lets this
/// Mac use the free cmux AI model without a sign-in. The local model relay
/// then proves the Mac to the cmux API (App Attest) at the first signed-out
/// agent request, never at launch. An MDM profile or a team policy can force
/// it off; a Mac that cannot prove itself shows sign-in instead.
public nonisolated struct FreeModelSettings: Sendable, Equatable {
    public var enabled = FreeModelSettings.enabledDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["freeModel"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        diagnostics = reader.diagnostics
        return settings
    }
}
