import CmuxNextSettings
import Testing

/// `terminal.term` (Lawrence 2026-10-28): unset unless the person names a terminfo entry; a bad value stays
/// unset and says why; the Settings row's default is the standard xterm-256color and agents may not set it.
struct TerminalTermSettingTests {
    private func snapshot(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["terminal": .object(["term": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func absentIsUnset() {
        #expect(snapshot(nil).terminalTerm == nil)
        #expect(snapshot(.string("  ")).terminalTerm == nil)
    }

    @Test func aTerminfoNameIsRead() {
        for name in ["xterm-ghostty", "xterm-256color", "tmux-256color"] {
            let parsed = snapshot(.string(name))
            #expect(parsed.terminalTerm == name)
            #expect(!parsed.diagnostics.contains { $0.path == "terminal.term" })
        }
    }

    @Test func aBadValueStaysUnsetWithADiagnostic() {
        for value: JSONValue in [.string("../x"), .string("a b"), .bool(true), .number(1)] {
            let parsed = snapshot(value)
            #expect(parsed.terminalTerm == nil)
            #expect(parsed.diagnostics.contains { $0.path == "terminal.term" })
        }
    }

    @Test func theSettingsRowDefaultsToTheStandardTerm() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == "terminal.term" })
        #expect(row.defaultValue == .string("xterm-256color"))
        #expect(!SettingsSchema.agentSettableKeys.contains("terminal.term"))
        #expect(SettingsSchema.agentRefusedKeys["terminal.term"] == .userOnly)
    }
}
