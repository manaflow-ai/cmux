import CmuxNextSettings
import Testing

/// `layout.focusFollowsMouse`: off by default (the user, Oct 20: a hover or scroll over another
/// pane must not pull focus out of the field being typed in), Settings lists the toggle, and a bad value
/// keeps it off with a diagnostic.
struct FocusFollowsMouseSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["layout": .object(["focusFollowsMouse": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.focusFollowsMouse == false)
        #expect(!snapshot.diagnostics.contains { $0.path == "layout.focusFollowsMouse" })
    }

    @Test func theUserCanTurnItOffAndOn() {
        #expect(Self.parse(.bool(false)).focusFollowsMouse == false)
        #expect(Self.parse(.bool(true)).focusFollowsMouse)
    }

    @Test func aBadValueKeepsItOffAndSaysWhy() {
        let snapshot = Self.parse(.string("on"))
        #expect(snapshot.focusFollowsMouse == false)
        #expect(snapshot.diagnostics.contains { $0.path == "layout.focusFollowsMouse" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["layout", "focusFollowsMouse"]))
        #expect(descriptor.defaultValue == .bool(false))
    }
}
