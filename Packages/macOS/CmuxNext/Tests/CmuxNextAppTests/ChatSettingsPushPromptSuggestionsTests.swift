@testable import CmuxNextSettings
import Testing

/// acpmux reads only the settings file, so an `agents.promptSuggestions` that MDM or the team policy
/// forces reaches it only through the app's settings push (`_acpmux/chat_settings` `promptSuggestions`,
/// `promptSuggestionsManaged`). Review of cmux#33097: a forced off still started suggestions, each one
/// an extra model call on the person's usage.
struct ChatSettingsPushPromptSuggestionsTests {
    private func push(file: JSONValue, managed: ManagedPreferences = ManagedPreferences(),
                      team: TeamPolicyLayer = .none) -> JSONValue {
        let effective = EffectiveSettings.merge(file: file, managed: managed, team: team)
        return ChatSettings(effective: effective.root, file: file, managedRoots: [], managedKeys: effective.managedKeys).params
    }

    private let on: JSONValue = .object(["agents": .object(["promptSuggestions": .bool(true)])])
    private let off: JSONValue = .object(["agents": .object(["promptSuggestions": .bool(false)])])

    @Test func anOffMDMForcesGoesOutManagedOverTheFile() {
        let params = push(file: on, managed: ManagedPreferences(forced: ["agents.promptSuggestions": .bool(false)]))
        #expect(params["promptSuggestions"]?.boolValue == false, "\(params)")
        #expect(params["promptSuggestionsManaged"]?.boolValue == true, "\(params)")
    }

    @Test func anOnMDMForcesGoesOutManagedOverAnOffFile() {
        let params = push(file: off, managed: ManagedPreferences(forced: ["agents.promptSuggestions": .bool(true)]))
        #expect(params["promptSuggestions"]?.boolValue == true, "\(params)")
        #expect(params["promptSuggestionsManaged"]?.boolValue == true, "\(params)")
    }

    @Test func theTeamPolicyEnforcedOffGoesOutManaged() {
        let team = TeamPolicyLayer(teamName: "Acme", enforced: ["agents.promptSuggestions": .bool(false)])
        let params = push(file: on, team: team)
        #expect(params["promptSuggestions"]?.boolValue == false, "\(params)")
        #expect(params["promptSuggestionsManaged"]?.boolValue == true, "\(params)")
    }

    @Test func withNothingForcedTheFileDecides() {
        for file in [on, off, .object([:])] {
            let params = push(file: file)
            #expect(params["promptSuggestions"] == .null, "\(params)")
            #expect(params["promptSuggestionsManaged"]?.boolValue == false, "\(params)")
        }
    }
}
