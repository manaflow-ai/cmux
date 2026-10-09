import Testing
@testable import CmuxNextSettings

/// `agentPane.showContextUsage` (General > Agent Chat): whether the composer shows its context
/// usage ring. On by default; the ring's right-click hides it and the footer's shows it again.
/// The page reads the same name (acpmux/composerSettings.ts).
@Suite struct AgentPaneComposerSettingTests {
    static func snapshot(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func showContextUsageIsAToggleRowThatIsOnByDefault() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["agentPane", "showContextUsage"]))
        guard case .toggle = row.kind else { Issue.record("showContextUsage is not a toggle"); return }
        #expect(row.defaultValue == .bool(true))
        #expect(row.section == .general)
        #expect(SettingsSchema.agentSettable(row) == true)
    }

    @Test func cmuxJSONReachesTheSnapshotAndThePage() throws {
        #expect(try Self.snapshot("{}").agentPaneComposer == .fallback)
        #expect(AgentPaneComposerSetting.fallback.pageValue == ["showContextUsage": true])
        let snapshot = try Self.snapshot(#"{"agentPane": {"showContextUsage": false}}"#)
        #expect(snapshot.diagnostics.isEmpty)
        #expect(snapshot.agentPaneComposer.pageValue == ["showContextUsage": false])
    }
}
