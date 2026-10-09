import Foundation
import Testing
@testable import CmuxNextSettings

/// `app.startAgentGlobalHotKey` (cx-hkat): Start Agent from Any App takes
/// its system-wide key (Ctrl-Opt-Cmd-Space by default) only when the user
/// turns it on, like `app.globalHotKey` for Show/Hide All Windows.
@Suite struct StartAgentGlobalHotKeySettingTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() throws {
        let snapshot = try parse("{}")
        #expect(!snapshot.startAgentGlobalHotKey)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func onWhenTheUserTurnsItOn() throws {
        #expect(try parse(#"{"app": {"startAgentGlobalHotKey": true}}"#).startAgentGlobalHotKey)
        #expect(try !parse(#"{"app": {"startAgentGlobalHotKey": false}}"#).startAgentGlobalHotKey)
        // Independent of Show/Hide All Windows' key.
        #expect(try !parse(#"{"app": {"globalHotKey": true}}"#).startAgentGlobalHotKey)
    }

    @Test func invalidValuesStayOffWithADiagnostic() throws {
        let snapshot = try parse(#"{"app": {"startAgentGlobalHotKey": 1}}"#)
        #expect(!snapshot.startAgentGlobalHotKey)
        #expect(snapshot.diagnostics.map(\.path) == ["app.startAgentGlobalHotKey"])
    }

    @Test func schemaShowsAnOffToggleAgentsCannotSet() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.startAgentGlobalHotKeyPath))
        guard case .toggle = descriptor.kind else { Issue.record("app.startAgentGlobalHotKey is not a toggle"); return }
        #expect(descriptor.defaultValue == .bool(false))
        #expect(SettingsSchema.agentSettable(descriptor) == false)
    }
}
