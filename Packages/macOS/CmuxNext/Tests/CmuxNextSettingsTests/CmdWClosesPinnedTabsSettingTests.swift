import Foundation
import Testing
@testable import CmuxNextSettings

/// `tabs.cmdWClosesPinnedTabs` (PINNED-ITEMS-END-TO-END amendment 1): off by
/// default, so Cmd-W keeps a pinned tab; on, Cmd-W closes it.
@Suite struct CmdWClosesPinnedTabsSettingTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToKeepingPinnedTabs() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.cmdWClosesPinnedTabs == false)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsTheChoice() throws {
        let snapshot = try parse(#"{"tabs": {"cmdWClosesPinnedTabs": true}}"#)
        #expect(snapshot.cmdWClosesPinnedTabs)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func invalidValuesUseTheDefaultWithADiagnostic() throws {
        let snapshot = try parse(#"{"tabs": {"cmdWClosesPinnedTabs": "yes"}}"#)
        #expect(snapshot.cmdWClosesPinnedTabs == CmdWClosesPinnedTabsSetting.fallback)
        #expect(snapshot.diagnostics.map(\.path) == ["tabs.cmdWClosesPinnedTabs"])
    }

    @Test func schemaExposesTheToggleWithTheSameDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: CmdWClosesPinnedTabsSetting.configPath))
        guard case .toggle = descriptor.kind else {
            Issue.record("tabs.cmdWClosesPinnedTabs is not a toggle")
            return
        }
        #expect(descriptor.defaultValue == .bool(CmdWClosesPinnedTabsSetting.fallback))
        #expect(CmdWClosesPinnedTabsSetting.fallback == false)
    }
}
