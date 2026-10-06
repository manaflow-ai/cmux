import Foundation
import Testing
@testable import CmuxNextSettings

/// `app.warnBeforeClosingTab` and `app.warnBeforeClosingAgentSession`, the
/// keys classic uses (#17430, #17501): both on unless turned off.
@Suite struct CloseWarningSettingsTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func bothWarningsAreOnByDefault() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.warnBeforeClosingTab)
        #expect(snapshot.warnBeforeClosingAgentSession)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func eachTurnsOffOnItsOwn() throws {
        let tab = try parse(#"{"app": {"warnBeforeClosingTab": false}}"#)
        #expect(!tab.warnBeforeClosingTab && tab.warnBeforeClosingAgentSession)
        let agent = try parse(#"{"app": {"warnBeforeClosingAgentSession": false}}"#)
        #expect(agent.warnBeforeClosingTab && !agent.warnBeforeClosingAgentSession)
    }

    @Test func invalidValuesStayOnWithADiagnostic() throws {
        let snapshot = try parse(#"{"app": {"warnBeforeClosingTab": "no"}}"#)
        #expect(snapshot.warnBeforeClosingTab)
        #expect(snapshot.diagnostics.map(\.path) == ["app.warnBeforeClosingTab"])
    }

    @Test func schemaShowsBothTogglesAndAgentsCannotTurnThemOff() throws {
        for path in [CloseWarningSetting.tabPath, CloseWarningSetting.agentSessionPath] {
            let descriptor = try #require(SettingsSchema.descriptor(for: path))
            guard case .toggle = descriptor.kind else { Issue.record("\(path) is not a toggle"); continue }
            #expect(descriptor.defaultValue == .bool(true))
            #expect(SettingsSchema.agentSettable(descriptor) == false)
        }
    }
}
