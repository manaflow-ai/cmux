@testable import CmuxNextSettings
import Testing

/// `terminal.term` (``TerminalTerm``): the `TERM` new terminals start with.
@Suite struct TerminalTermSettingTests {
    private func snapshot(_ terminal: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["terminal": .object(terminal)]), validDensities: [], validMetrics: [])
    }

    @Test func xterm256colorWhenCmuxJSONSaysNothing() {
        let parsed = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(parsed.terminalTerm == .xterm256color)
        #expect(parsed.diagnostics.isEmpty)
    }

    @Test func xtermGhosttyIsTheOptIn() {
        let parsed = snapshot(["term": .string("xterm-ghostty")])
        #expect(parsed.terminalTerm == .xtermGhostty)
        #expect(parsed.diagnostics.isEmpty)
    }

    @Test(arguments: [JSONValue.string("screen-256color"), .bool(true), .string("")])
    func anUnknownValueIsTheDefaultPlusADiagnostic(_ value: JSONValue) {
        let parsed = snapshot(["term": value])
        #expect(parsed.terminalTerm == .xterm256color)
        #expect(parsed.diagnostics.map(\.path).contains("terminal.term"))
    }
}
