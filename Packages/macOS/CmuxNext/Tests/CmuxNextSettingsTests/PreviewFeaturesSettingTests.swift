import Testing
@testable import CmuxNextSettings

/// `labs.previewFeatures` (Settings > Advanced > Labs): off by default, so
/// a default app shows only finished surfaces; `true` turns it on, and
/// anything else is off with a diagnostic.
@Suite struct PreviewFeaturesSettingTests {
    @Test func offUnlessTrue() {
        let unset = CmuxConfigSnapshot.parsePreviewFeatures(.object([:]))
        #expect(unset.0 == false && unset.1 == nil)
        let on = CmuxConfigSnapshot.parsePreviewFeatures(.object(["labs": .object(["previewFeatures": .bool(true)])]))
        #expect(on.0 == true && on.1 == nil)
        let wrong = CmuxConfigSnapshot.parsePreviewFeatures(.object(["labs": .object(["previewFeatures": .string("yes")])]))
        #expect(wrong.0 == false)
        #expect(wrong.1?.path == "labs.previewFeatures")
    }

    @Test func theToggleIsUnderAdvancedAndOff() throws {
        let row = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.previewFeaturesPath))
        #expect(row.section == .advanced)
        #expect(row.kind == .toggle)
        #expect(row.defaultValue == .bool(false))
        #expect(SettingsSchema.agentSettableKeys.contains(row.id))
    }
}
