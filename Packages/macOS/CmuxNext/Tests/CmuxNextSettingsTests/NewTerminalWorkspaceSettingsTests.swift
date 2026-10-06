import Foundation
import Testing
@testable import CmuxNextSettings

/// `newTerminal.opensWorkspace` controls the persistent New Terminal target;
/// Option on a New Terminal control flips that choice for one activation.
@Suite struct NewTerminalWorkspaceSettingsTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToTabs() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.newTerminalOpensWorkspace == false)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsTheWorkspaceChoice() throws {
        let snapshot = try parse(#"{"newTerminal": {"opensWorkspace": true}}"#)
        #expect(snapshot.newTerminalOpensWorkspace)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func invalidValuesUseTheDefaultWithADiagnostic() throws {
        let snapshot = try parse(#"{"newTerminal": {"opensWorkspace": "yes"}}"#)
        #expect(snapshot.newTerminalOpensWorkspace == NewTerminalWorkspaceSetting.fallback)
        #expect(snapshot.diagnostics.map(\.path) == ["newTerminal.opensWorkspace"])
    }

    @Test func optionTogglesThePersistentChoice() {
        #expect(NewTerminalWorkspaceSetting.resolves(setting: false, toggled: false) == false)
        #expect(NewTerminalWorkspaceSetting.resolves(setting: false, toggled: true))
        #expect(NewTerminalWorkspaceSetting.resolves(setting: true, toggled: false))
        #expect(NewTerminalWorkspaceSetting.resolves(setting: true, toggled: true) == false)
    }

    @Test func schemaExposesTheToggle() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: NewTerminalWorkspaceSetting.configPath))
        guard case .toggle = descriptor.kind else {
            Issue.record("newTerminal.opensWorkspace is not a toggle")
            return
        }
        #expect(descriptor.defaultValue == .bool(false))
    }
}
