import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `tabs.shellIconTheme`: a Tabs row on the Settings page, "default" unless cmux.json says "machine", and the
/// applier hands the choice to `DesignSettings`, which the tab strip reads.
struct TabShellIconThemeSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let tabs: [String: JSONValue] = value.map { ["shellIconTheme": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["tabs": .object(tabs)]), validDensities: [], validMetrics: [])
    }

    @Test func isATabsChoiceOnTheSettingsPage() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: TabShellIconThemeSetting.configPath))
        #expect(TabShellIconThemeSetting.configPath == ["tabs", "shellIconTheme"])
        #expect(descriptor.isShownOnSettingsPage)
        #expect(descriptor.defaultValue == .string(TabShellIconTheme.default.rawValue))
        guard case .choice(let choices) = descriptor.kind else { Issue.record("not a choice row"); return }
        #expect(choices.map(\.value) == TabShellIconTheme.allCases.map(\.rawValue))
    }

    @Test func machineIsReadAndUnsetIsDefault() {
        #expect(Self.parse(.string("machine")).tabShellIconTheme == .machine)
        #expect(Self.parse(.string("default")).tabShellIconTheme == .default)
        #expect(Self.parse(nil).tabShellIconTheme == .default)
        #expect(!Self.parse(.string("machine")).diagnostics.contains { $0.path == "tabs.shellIconTheme" })
    }

    @Test func badValueUsesDefaultAndReportsIt() {
        let snapshot = Self.parse(.string("planets"))
        #expect(snapshot.tabShellIconTheme == .default)
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.shellIconTheme" })
    }
}
