@testable import CmuxNextSettings
import Testing

/// `launch.savedPicture` (``LaunchSavedPictureSetting``): on by default, off only for a literal
/// `false`, one toggle row off the page while its feature is off, and refused to agents (the pictures hold
/// terminal text and pages).
struct LaunchSavedPictureSettingTests {
    @Test func aMissingOrMalformedValueIsOn() {
        #expect(LaunchSavedPictureSetting().value(in: .object([:])))
        #expect(LaunchSavedPictureSetting().value(in: .object(["launch": .object(["savedPicture": .string("no")])])))
        #expect(LaunchSavedPictureSetting().value(in: .object(["launch": .string("off")])))
    }

    @Test func falseTurnsItOff() {
        let root = JSONValue.object(["launch": .object(["savedPicture": .bool(false)])])
        #expect(!LaunchSavedPictureSetting().value(in: root))
        #expect(LaunchSavedPictureSetting().value(in: .object(["launch": .object(["savedPicture": .bool(true)])])))
    }

    @Test func theSchemaRowIsAToggleThatDefaultsOn() throws {
        let row = try #require(SettingsSchema.all.first { $0.id == "launch.savedPicture" })
        #expect(row.kind == .toggle)
        #expect(row.defaultValue == .bool(true))
        #expect(row.section == .general)
        #expect(row.textKeys.title == "settings.launch.savedPicture")
        #expect(!row.isShownOnSettingsPage, "the row stays off the page while savedWindowPicture is off by default")
    }

    @Test func agentsCannotSetIt() {
        #expect(SettingsSchema.agentRefusedKeys["launch.savedPicture"] == .privacy)
        #expect(!SettingsSchema.agentSettableKeys.contains("launch.savedPicture"))
    }
}
