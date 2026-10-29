import CmuxNextSettings
import Testing

/// `terminal.predictiveEcho`: off unless the person picks remote or always; a bad
/// value stays off and says why; the Settings row offers the same three values.
struct TerminalPredictiveEchoSettingTests {
    private func snapshot(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["terminal": .object(["predictiveEcho": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func absentIsOff() {
        #expect(snapshot(nil).terminalPredictiveEcho == .off)
        #expect(TerminalPredictiveEchoSetting.fallback == .off)
    }

    @Test(arguments: TerminalPredictiveEchoSetting.allCases)
    func eachValueIsRead(_ setting: TerminalPredictiveEchoSetting) {
        let parsed = snapshot(.string(setting.rawValue))
        #expect(parsed.terminalPredictiveEcho == setting)
        #expect(!parsed.diagnostics.contains { $0.path == "terminal.predictiveEcho" })
    }

    @Test func aBadValueStaysOffWithADiagnostic() {
        for value: JSONValue in [.string("sometimes"), .bool(true), .number(1)] {
            let parsed = snapshot(value)
            #expect(parsed.terminalPredictiveEcho == .off)
            #expect(parsed.diagnostics.contains { $0.path == "terminal.predictiveEcho" })
        }
    }

    @Test func theSettingsRowOffersTheParsersValuesAndDefault() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == "terminal.predictiveEcho" })
        #expect(row.defaultValue == .string("off"))
        guard case .choice(let choices) = row.kind else {
            Issue.record("terminal.predictiveEcho is not a choice row")
            return
        }
        #expect(choices.map(\.value) == TerminalPredictiveEchoSetting.allCases.map(\.rawValue))
        #expect(SettingsSchema.agentSettableKeys.contains("terminal.predictiveEcho"))
    }
}
