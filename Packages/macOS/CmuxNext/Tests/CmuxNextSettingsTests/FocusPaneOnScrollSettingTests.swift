import CmuxNextSettings
import Testing

/// `layout.focusPaneOnScroll`: off by default (the user, Oct 20: a scroll over another pane must
/// not pull focus out of the field being typed in), Settings lists the toggle, and a bad value
/// keeps it off with a diagnostic.
struct FocusPaneOnScrollSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["layout": .object(["focusPaneOnScroll": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.focusPaneOnScroll == false)
        #expect(!snapshot.diagnostics.contains { $0.path == "layout.focusPaneOnScroll" })
    }

    @Test func theUserCanTurnItOffAndOn() {
        #expect(Self.parse(.bool(false)).focusPaneOnScroll == false)
        #expect(Self.parse(.bool(true)).focusPaneOnScroll)
    }

    @Test func aBadValueKeepsItOffAndSaysWhy() {
        let snapshot = Self.parse(.string("on"))
        #expect(snapshot.focusPaneOnScroll == false)
        #expect(snapshot.diagnostics.contains { $0.path == "layout.focusPaneOnScroll" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["layout", "focusPaneOnScroll"]))
        #expect(descriptor.defaultValue == .bool(false))
    }
}
