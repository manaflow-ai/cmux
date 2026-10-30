import CmuxNextSettings
import Testing

/// `tabs.nativeNewTabPage` (Lawrence 2026-10-29): the native New Tab page is an alternative, off by
/// default, so Cmd-T keeps opening the web page; Settings lists the toggle; a bad value keeps the default.
struct NativeNewTabPageSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["tabs": .object(["nativeNewTabPage": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.nativeNewTabPage == false)
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOn() {
        #expect(Self.parse(.bool(true)).nativeNewTabPage)
        #expect(Self.parse(.bool(false)).nativeNewTabPage == false)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.nativeNewTabPage == false)
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.nativeNewTabPage" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOff() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["tabs", "nativeNewTabPage"]))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.section == .general)
    }
}
