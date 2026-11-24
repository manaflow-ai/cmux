import CmuxNextSettings
import Testing

/// `app.language`: nil (System) when unset, `system` or a value cmux does not ship; any shipped
/// locale as itself. A value cmux does not ship also says so in the diagnostics.
struct AppLanguageSettingTests {
    private static func snapshot(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    private static func language(_ value: JSONValue) -> JSONValue {
        .object(["app": .object(["language": value])])
    }

    @Test func systemWhenUnset() {
        let snapshot = Self.snapshot(.object([:]))
        #expect(snapshot.appLanguage == nil)
        #expect(!snapshot.diagnostics.contains { $0.path == "app.language" })
    }

    @Test func systemIsNil() {
        let snapshot = Self.snapshot(Self.language(.string(AppLanguageSetting.systemValue)))
        #expect(snapshot.appLanguage == nil)
        #expect(!snapshot.diagnostics.contains { $0.path == "app.language" })
    }

    @Test(arguments: ["ja", "zh-Hant", "pt-BR"])
    func aShippedLocaleIsItself(code: String) {
        let snapshot = Self.snapshot(Self.language(.string(code)))
        #expect(snapshot.appLanguage == code)
        #expect(!snapshot.diagnostics.contains { $0.path == "app.language" })
    }

    @Test(arguments: [JSONValue.string("klingon"), .string("JA"), .number(1), .bool(true), .null])
    func anUnshippedValueIsSystemWithADiagnostic(value: JSONValue) {
        let snapshot = Self.snapshot(Self.language(value))
        #expect(snapshot.appLanguage == nil)
        #expect(snapshot.diagnostics.contains { $0.path == "app.language" && $0.kind == .invalidValue })
    }
}
