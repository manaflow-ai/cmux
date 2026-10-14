import CmuxNextSettings
import Testing

/// The pane's top-right buttons became one hover "…" whose menu lists every action (Leo
/// 2026-10-12), so nothing reads `tabs.hiddenButtons` (the action ids right-clicked off the old
/// row). It is a retired key: Settings and the schema drop it, and an old file still loads cleanly.
struct PaneToolbarHiddenButtonsRetiredTests {
    @Test func anOldHiddenButtonsListLoadsWithoutADiagnostic() {
        let root = JSONValue.object(["tabs": .object(["hiddenButtons": .array([.string("splitDown"), .number(3)])])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(!snapshot.diagnostics.contains { $0.path == "tabs.hiddenButtons" })
        #expect(snapshot.retiredKeys == ["tabs.hiddenButtons"])
    }

    /// Settings offers no row for it, and a `settings.set` says it was removed.
    @Test func settingsHasNoHiddenButtonsRow() {
        #expect(SettingsSchema.descriptor(for: ["tabs", "hiddenButtons"]) == nil)
        #expect(SettingsSchema.isRetired(["tabs", "hiddenButtons"]))
    }
}
