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

    /// `cloud.defaultImage` (Settings > Cloud > Default Image): Auto unless an environment id is set,
    /// and the chat page follows it, so a new Cloud chat starts from it.
    @Test func defaultImageIsAutoUnlessSetAndTheChatFollowsIt() throws {
        let setting = CloudNewWorkspaceSetting()
        #expect(setting.defaultImage(in: .object([:])) == "auto")
        #expect(setting.defaultImage(in: .object(["cloud": .object(["defaultImage": .string("")])])) == "auto")
        #expect(setting.defaultImage(in: .object(["cloud": .object(["defaultImage": .bool(true)])])) == "auto")
        let picked = JSONValue.object(["cloud": .object(["defaultImage": .string("env_000000000000000000000123")])])
        #expect(setting.defaultImage(in: picked) == "env_000000000000000000000123")
        let row = try #require(SettingsSchema.all.first { $0.id == "cloud.defaultImage" })
        #expect(row.section == .machines)
        #expect(row.defaultValue == .string("auto"))
        #expect(row.isShownOnSettingsPage)
        // The environment every new Cloud chat boots in, with its setup and egress: the person picks it.
        #expect(SettingsSchema.agentRefusedKeys["cloud.defaultImage"] == .userOnly)
        #expect(!SettingsSchema.agentSettableKeys.contains("cloud.defaultImage"))
        #expect(AgentPaneDisplaySetting.followedAppPaths.contains(CloudNewWorkspaceSetting.defaultImagePath))
        #expect(AgentPaneDisplaySetting(fileRoot: picked).values["cloud.defaultImage"] == .string("env_000000000000000000000123"))
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
