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

    @Test func personalGitHubLoginRequiresExplicitOptIn() throws {
        let setting = CloudNewWorkspaceSetting()
        let granted = JSONValue.object(["cloud": .object(["useMyGitHubLogin": .bool(true)])])
        #expect(!setting.useMyGitHubLogin(personal: .object([:]), effective: granted))
        for value in [JSONValue.bool(false), .string("true"), .null] {
            let root = JSONValue.object(["cloud": .object(["useMyGitHubLogin": value])])
            #expect(!setting.useMyGitHubLogin(personal: root, effective: granted))
            #expect(!setting.useMyGitHubLogin(personal: granted, effective: root))
        }
        #expect(setting.useMyGitHubLogin(personal: granted, effective: granted))
        let row = try #require(SettingsSchema.all.first { $0.id == "cloud.useMyGitHubLogin" })
        #expect(row.defaultValue == .bool(false))
        #expect(row.isShownOnSettingsPage)
        #expect(SettingsSchema.agentRefusedKeys[row.id] == .userOnly)
    }

    @Test func personalGitHubLoginPolicyCanDisableSharingButCannotGrantIt() {
        let key = "cloud.useMyGitHubLogin"
        let setting = CloudNewWorkspaceSetting()
        let path = CloudNewWorkspaceSetting.useMyGitHubLoginPath
        let granted = JSONValue.object([:]).setting(.bool(true), at: path)
        let policyOn = [key: JSONValue.bool(true)]
        let policyOff = [key: JSONValue.bool(false)]
        let managersOn = ManagedPreferences(forced: policyOn, recommended: policyOn)
        let teamOn = TeamPolicyLayer(defaults: policyOn, enforced: policyOn)
        for file in [JSONValue.object([:]), .object([:]).setting(.bool(false), at: path), granted] {
            let result = EffectiveSettings.merge(file: file, managed: managersOn, team: teamOn)
            #expect(result.root.value(at: path) == file.value(at: path))
            #expect(result.managedKeys[key] == nil)
            #expect(setting.useMyGitHubLogin(personal: result.fileRoot, effective: result.root) == (file == granted))
        }
        let teamOff = TeamPolicyLayer(teamName: "Team", enforced: policyOff)
        let disabled = EffectiveSettings.merge(file: granted, managed: managersOn, team: teamOff)
        #expect(disabled.managedKeys[key] == .team("Team"))
        #expect(!setting.useMyGitHubLogin(personal: disabled.fileRoot, effective: disabled.root))
        let deviceOff = EffectiveSettings.merge(file: granted, managed: ManagedPreferences(forced: policyOff), team: teamOn)
        #expect(deviceOff.managedKeys[key] == .device)
        #expect(!setting.useMyGitHubLogin(personal: deviceOff.fileRoot, effective: deviceOff.root))
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

    /// Leo, 2026-11-27: "remember we need to be able to toggle a chat on and off of autocloud"; "IT JUST SIMPLY MUST BE AN OPTION."
    @Test func autoCloudOffersEachChatLocalAndAutoAndCloudToggleAllThree() {
        #expect(CmuxConfigSnapshot.placeModes(cloudToggle: false, autoCloud: false).isEmpty)
        #expect(CmuxConfigSnapshot.placeModes(cloudToggle: false, autoCloud: true) == ["local", "auto"])
        #expect(CmuxConfigSnapshot.placeModes(cloudToggle: true, autoCloud: false) == ["local", "cloud", "auto"])
        #expect(CmuxConfigSnapshot.placeModes(cloudToggle: true, autoCloud: true) == ["local", "cloud", "auto"])
    }
}
