@testable import CmuxNextSettings
import Testing

/// `agents.chats.terminalChatWritable` reaches acpmux only through the app's settings push
/// (`_acpmux/chat_settings` `terminalChatWritable`, `hub/release_to_watch.rs`): off by default, on
/// from the file, and MDM or the team policy may only force it off, like the other chat switches.
struct ChatSettingsPushTerminalChatWritableTests {
    private func push(file: JSONValue, managed: ManagedPreferences = ManagedPreferences(),
                      team: TeamPolicyLayer = .none) -> JSONValue {
        let effective = EffectiveSettings.merge(file: file, managed: managed, team: team)
        return ChatSettings(effective: effective.root, file: file, managedRoots: [], managedKeys: effective.managedKeys).params
    }

    private let on: JSONValue = .object(["agents": .object(["chats": .object(["terminalChatWritable": .bool(true)])])])

    @Test func offByDefault() {
        #expect(push(file: .object([:]))["terminalChatWritable"]?.boolValue == false)
    }

    @Test func theFileTurnsItOn() {
        #expect(push(file: on)["terminalChatWritable"]?.boolValue == true)
    }

    @Test func mdmForcesItOffOverTheFile() {
        let params = push(file: on, managed: ManagedPreferences(forced: ["agents.chats.terminalChatWritable": .bool(false)]))
        #expect(params["terminalChatWritable"]?.boolValue == false, "\(params)")
    }
}
