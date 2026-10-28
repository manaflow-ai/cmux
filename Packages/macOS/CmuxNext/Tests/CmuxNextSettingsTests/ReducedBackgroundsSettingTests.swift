import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `ui.reducedBackgrounds`: off by default, so windows draw the person's backgrounds; on, it is
/// one toggle in Appearance, and it never rewrites the `appearance.*` values it overrides.
struct ReducedBackgroundsSettingTests {
    static func parse(_ value: JSONValue?, appearance: [String: JSONValue] = [:]) -> CmuxConfigSnapshot {
        var root: [String: JSONValue] = [:]
        if let value { root["ui"] = .object(["reducedBackgrounds": value]) }
        if !appearance.isEmpty { root["appearance"] = .object(appearance) }
        return CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.reducedBackgrounds == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOn() {
        #expect(Self.parse(.bool(true)).reducedBackgrounds)
        #expect(Self.parse(.bool(false)).reducedBackgrounds == false)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.reducedBackgrounds == false)
        #expect(snapshot.diagnostics.contains { $0.path == "ui.reducedBackgrounds" }, "\(snapshot.diagnostics)")
    }

    /// The person's picture and material stay in the snapshot; only what is drawn changes.
    @Test func onKeepsThePersonsAppearanceValues() {
        let snapshot = Self.parse(.bool(true), appearance: ["background": .string("van-gogh-starry-night"),
                                                            "backgroundBlur": .string("glass")])
        #expect(snapshot.reducedBackgrounds)
        #expect(snapshot.backdropSelection?.id == "van-gogh-starry-night")
        #expect(snapshot.windowBackground.material == .glass)
        let glass = snapshot.windowBackground
        #expect(ReducedBackgroundsSetting.drawn(glass, reduced: false) == glass)
        // Opaque and unblurred whatever the Ghostty config says (here a translucent glass window).
        let plain = ReducedBackgroundsSetting.drawn(glass, reduced: true).resolved(backgroundOpacity: 0.7, backgroundBlur: -1)
        #expect(plain.backgroundOpacity == 1)
        #expect(plain.backgroundBlur == 0)
    }

    @Test func settingsListsTheToggleOffInAppearance() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["ui", "reducedBackgrounds"]))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.section == .appearance)
    }
}
