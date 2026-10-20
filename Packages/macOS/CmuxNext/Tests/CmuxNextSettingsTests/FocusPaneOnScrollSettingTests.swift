import CmuxNextSettings
import Testing

/// `layout.focusPaneOnScroll` (u2246): on by default, Settings lists the toggle, and a bad value
/// keeps it on with a diagnostic.
struct FocusPaneOnScrollSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["layout": .object(["focusPaneOnScroll": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func onByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.focusPaneOnScroll)
        #expect(!snapshot.diagnostics.contains { $0.path == "layout.focusPaneOnScroll" })
    }

    @Test func theUserCanTurnItOffAndOn() {
        #expect(Self.parse(.bool(false)).focusPaneOnScroll == false)
        #expect(Self.parse(.bool(true)).focusPaneOnScroll)
    }

    @Test func aBadValueKeepsItOnAndSaysWhy() {
        let snapshot = Self.parse(.string("off"))
        #expect(snapshot.focusPaneOnScroll)
        #expect(snapshot.diagnostics.contains { $0.path == "layout.focusPaneOnScroll" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOnByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["layout", "focusPaneOnScroll"]))
        #expect(descriptor.defaultValue == .bool(true))
    }
}
