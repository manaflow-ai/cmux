import CmuxNextSettings
import Testing

/// `tabs.cmdWClosesPinnedTabs`: Cmd-W closes a pinned tab by default, as Chrome's Cmd-W does
/// (Leo 2026-10-19); off keeps the pinned tab and selects the next one. Settings lists the toggle
/// on, and a bad value keeps the default with a diagnostic.
struct CmdWClosesPinnedTabsSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["tabs": .object(["cmdWClosesPinnedTabs": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func cmdWClosesPinnedTabsByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.cmdWClosesPinnedTabs)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanKeepPinnedTabs() {
        #expect(Self.parse(.bool(false)).cmdWClosesPinnedTabs == false)
        #expect(Self.parse(.bool(true)).cmdWClosesPinnedTabs)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("no"))
        #expect(snapshot.cmdWClosesPinnedTabs)
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.cmdWClosesPinnedTabs" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOnByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["tabs", "cmdWClosesPinnedTabs"]))
        #expect(descriptor.defaultValue == .bool(true))
    }
}
