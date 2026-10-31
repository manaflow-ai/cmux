import CmuxNextSettings
import Testing

/// `layout.scrollAreas` (plans/cmux-next/scroll-areas-DESIGN.md): off by default, the user can turn
/// it on, Settings lists the toggle, and a bad value keeps it off with a diagnostic.
struct ScrollAreasSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["layout": .object(["scrollAreas": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.layoutScrollAreas == false)
        #expect(!snapshot.diagnostics.contains { $0.path == "layout.scrollAreas" })
    }

    @Test func theUserCanTurnItOnAndOff() {
        #expect(Self.parse(.bool(true)).layoutScrollAreas)
        #expect(Self.parse(.bool(false)).layoutScrollAreas == false)
    }

    @Test func aBadValueKeepsItOffAndSaysWhy() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.layoutScrollAreas == false)
        #expect(snapshot.diagnostics.contains { $0.path == "layout.scrollAreas" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["layout", "scrollAreas"]))
        #expect(descriptor.defaultValue == .bool(false))
    }
}
