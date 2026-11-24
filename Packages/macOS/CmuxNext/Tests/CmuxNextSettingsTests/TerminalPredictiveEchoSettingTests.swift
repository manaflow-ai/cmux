@testable import CmuxNextSettings
import Testing

/// `terminal.predictiveLocalEcho` (``TerminalPredictiveEchoSetting``): remote terminals draw typed characters before
/// their echo; on unless cmux.json turns it off.
@Suite struct TerminalPredictiveEchoSettingTests {
    private func snapshot(_ terminal: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["terminal": .object(terminal)]), validDensities: [], validMetrics: [])
    }

    @Test func onWhenCmuxJSONSaysNothing() {
        let parsed = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(parsed.terminalPredictiveLocalEcho)
        #expect(parsed.diagnostics.isEmpty)
    }

    @Test func falseTurnsItOff() {
        let parsed = snapshot(["predictiveLocalEcho": .bool(false)])
        #expect(!parsed.terminalPredictiveLocalEcho)
        #expect(parsed.diagnostics.isEmpty)
    }

    @Test(arguments: [JSONValue.string("false"), .number(0)])
    func aValueThatIsNoBooleanIsTheDefaultPlusADiagnostic(_ value: JSONValue) {
        let parsed = snapshot(["predictiveLocalEcho": value])
        #expect(parsed.terminalPredictiveLocalEcho)
        #expect(parsed.diagnostics.map(\.path).contains("terminal.predictiveLocalEcho"))
    }

    @Test func theSchemaListsItAsAnAgentSettableToggle() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == "terminal.predictiveLocalEcho" })
        #expect(row.kind == .toggle)
        #expect(row.defaultValue == .bool(true))
        #expect(SettingsSchema.agentSettable(row) == true)
    }
}
