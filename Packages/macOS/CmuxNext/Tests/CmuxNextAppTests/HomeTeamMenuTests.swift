import AppKit
import CmuxNextActions
@testable import CmuxNextHomeEngine
import Testing

/// Home lists one team's people at a time (the user, 2026-10-29: "should only show for a team at a
/// time… no multi team"), so its menu offers Switch Active Team: the palette's and the CLI's one
/// action (`openTeamPicker`), with each team and the active one checked.
@MainActor @Suite struct HomeTeamMenuTests {
    static func registry(teams: [(String, String)], active: String?, chosen: @escaping (String?) -> Void) -> ActionRegistry {
        let registry = ActionRegistry(catalog: [
            ActionDescriptor(id: "openTeamPicker", title: "Switch Active Team…", category: .cloud),
        ])
        registry.bind("openTeamPicker", invoke: { invocation in chosen(invocation["team"]?.stringValue) })
        registry.argumentSuggestions = { source in
            source == ActionSuggestions.cloudTeams ? teams.map { ActionEnumCase(value: $0.0, title: $0.1) } : []
        }
        registry.choiceState = { action, _ in action == "openTeamPicker" ? active : nil }
        return registry
    }

    @Test func listsEachTeamAndSwitchesThroughTheAction() throws {
        var chosen: [String?] = []
        let registry = Self.registry(teams: [("t-cmux", "cmux"), ("t-ben", "Benjamin Swerdlow's Team")], active: "t-cmux") { chosen.append($0) }
        let item = try #require(HomePageMenus.teamMenu(registry: registry))
        let teams = try #require(item.submenu).items
        #expect(teams.map(\.title) == ["cmux", "Benjamin Swerdlow's Team"])
        #expect(teams.map(\.state) == [.on, .off])
        let other = teams[1]
        _ = (other.target as? NSObject)?.perform(other.action, with: other)
        #expect(chosen == ["t-ben"])
    }

    /// One team: nothing to switch to, so no item.
    @Test func oneTeamHasNoSwitcher() {
        let registry = Self.registry(teams: [("t-cmux", "cmux")], active: "t-cmux") { _ in }
        #expect(HomePageMenus.teamMenu(registry: registry) == nil)
    }
}
