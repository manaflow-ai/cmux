@testable import CmuxNextSettings
import Testing

/// `navigation.historyScope` (plans/cmux-next/history.md 4.2a, R69): workspace by default, the three
/// values parse, a bad value falls back with a diagnostic, and the schema row matches the default.
struct NavigationHistoryScopeSettingTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToWorkspaceAndParsesEveryValue() throws {
        #expect(try parse("{}").navigationHistoryScope == "workspace")
        for value in ["workspace", "window", "surface"] {
            #expect(try parse(#"{"navigation": {"historyScope": "\#(value)"}}"#).navigationHistoryScope == value)
        }
    }

    @Test func aBadValueFallsBackWithADiagnostic() throws {
        let snapshot = try parse(#"{"navigation": {"historyScope": "tab"}}"#)
        #expect(snapshot.navigationHistoryScope == "workspace")
        #expect(snapshot.diagnostics.contains { $0.path == "navigation.historyScope" })
    }

    @Test func theSchemaRowMatchesTheDefaultAndAgentsMaySetIt() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["navigation", "historyScope"]))
        #expect(row.defaultValue == .string("workspace"))
        #expect(SettingsSchema.agentSettableKeys.contains("navigation.historyScope"))
    }
}
