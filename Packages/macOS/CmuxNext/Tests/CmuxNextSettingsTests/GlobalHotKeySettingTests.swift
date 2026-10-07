import Foundation
import Testing
@testable import CmuxNextSettings

/// `app.globalHotKey`: Show/Hide All Windows is a system-wide key only when
/// the user turns it on (coordinator decision 2026-10-06; GPUI reads the
/// same key).
@Suite struct GlobalHotKeySettingTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() throws {
        let snapshot = try parse("{}")
        #expect(!snapshot.globalHotKey)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func onWhenTheUserTurnsItOn() throws {
        #expect(try parse(#"{"app": {"globalHotKey": true}}"#).globalHotKey)
        #expect(try !parse(#"{"app": {"globalHotKey": false}}"#).globalHotKey)
    }

    @Test func invalidValuesStayOffWithADiagnostic() throws {
        let snapshot = try parse(#"{"app": {"globalHotKey": "yes"}}"#)
        #expect(!snapshot.globalHotKey)
        #expect(snapshot.diagnostics.map(\.path) == ["app.globalHotKey"])
    }

    @Test func schemaShowsAnOffToggleAgentsCannotSet() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.globalHotKeyPath))
        guard case .toggle = descriptor.kind else { Issue.record("app.globalHotKey is not a toggle"); return }
        #expect(descriptor.defaultValue == .bool(false))
        #expect(SettingsSchema.agentSettable(descriptor) == false)
    }
}
