import CmuxNextSettings
import Testing

/// `layout.fadeInactivePanes`: off by default (no default flips), Settings lists the toggle, and a bad
/// value keeps it off with a diagnostic. Leo, 2026-11-12: "if i click into the app or click into you for
/// the workspace like focus anything the composer just the window the pane it should fade away".
struct FadeInactivePanesSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["layout": .object(["fadeInactivePanes": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.fadeInactivePanes == false)
        #expect(!snapshot.diagnostics.contains { $0.path == "layout.fadeInactivePanes" })
    }

    @Test func theUserCanTurnItOnAndOff() {
        #expect(Self.parse(.bool(true)).fadeInactivePanes)
        #expect(Self.parse(.bool(false)).fadeInactivePanes == false)
    }

    @Test func aBadValueKeepsItOffAndSaysWhy() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.fadeInactivePanes == false)
        #expect(snapshot.diagnostics.contains { $0.path == "layout.fadeInactivePanes" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["layout", "fadeInactivePanes"]))
        #expect(descriptor.defaultValue == .bool(false))
    }
}
