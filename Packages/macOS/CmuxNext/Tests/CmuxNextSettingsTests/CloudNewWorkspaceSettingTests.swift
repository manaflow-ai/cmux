import Testing
@testable import CmuxNextSettings

/// `cloud.newWorkspacesInCloud` and `cloud.newWorkspaceFolder` (#26062): read from cmux.json, and
/// offered in Settings > Machines and the palette's Toggle Setting.
struct CloudNewWorkspaceSettingTests {
    @Test func defaultsAreLocalAndInherit() {
        let setting = CloudNewWorkspaceSetting()
        #expect(setting.inCloud(in: .object([:])) == false)
        #expect(setting.folder(in: .object([:])) == .inherit)
    }

    @Test func readsTheWrittenValuesAndIgnoresBadOnes() {
        let setting = CloudNewWorkspaceSetting()
        let on = JSONValue.object(["cloud": .object(["newWorkspacesInCloud": .bool(true), "newWorkspaceFolder": .string("empty")])])
        #expect(setting.inCloud(in: on))
        #expect(setting.folder(in: on) == .empty)
        let bad = JSONValue.object(["cloud": .object(["newWorkspacesInCloud": .string("yes"), "newWorkspaceFolder": .string("home")])])
        #expect(setting.inCloud(in: bad) == false)
        #expect(setting.folder(in: bad) == .inherit)
    }

    @Test func theToggleIsOnTheSettingsPageAndInThePalette() throws {
        let toggle = try #require(SettingsSchema.all.first { $0.id == "cloud.newWorkspacesInCloud" })
        #expect(toggle.section == .machines)
        #expect(toggle.isShownOnSettingsPage)
        #expect(toggle.isPaletteExposed)
        let folder = try #require(SettingsSchema.all.first { $0.id == "cloud.newWorkspaceFolder" })
        #expect(folder.defaultValue == .string("inherit"))
        // An agent can't turn on copying the person's folders to a paid machine.
        #expect(SettingsSchema.agentRefusedKeys["cloud.newWorkspacesInCloud"] != nil)
        #expect(SettingsSchema.agentRefusedKeys["cloud.newWorkspaceFolder"] != nil)
    }
}
