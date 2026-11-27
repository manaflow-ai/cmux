@testable import CmuxNextSettings
import Testing

/// `agents.chats.sessionRecap` reaches acpmux only through the app's settings push
/// (`_acpmux/chat_settings` `sessionRecap`, `hub/away_recap.rs`): on by default, off from the
/// file, and MDM or the team policy may only force it off, like the other chat switches.
struct ChatSettingsPushSessionRecapTests {
    private func push(file: JSONValue, managed: ManagedPreferences = ManagedPreferences(),
                      team: TeamPolicyLayer = .none) -> JSONValue {
        let effective = EffectiveSettings.merge(file: file, managed: managed, team: team)
        return ChatSettings(effective: effective.root, file: file, managedRoots: [], managedKeys: effective.managedKeys).params
    }

    private let off: JSONValue = .object(["agents": .object(["chats": .object(["sessionRecap": .bool(false)])])])

    @Test func onByDefault() {
        #expect(push(file: .object([:]))["sessionRecap"]?.boolValue == true)
    }

    @Test func theFileTurnsItOff() {
        #expect(push(file: off)["sessionRecap"]?.boolValue == false)
    }

    @Test func mdmForcesItOffOverTheFile() {
        let on: JSONValue = .object(["agents": .object(["chats": .object(["sessionRecap": .bool(true)])])])
        let params = push(file: on, managed: ManagedPreferences(forced: ["agents.chats.sessionRecap": .bool(false)]))
        #expect(params["sessionRecap"]?.boolValue == false, "\(params)")
    }
}
