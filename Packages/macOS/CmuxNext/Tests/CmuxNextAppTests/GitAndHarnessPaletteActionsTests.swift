@testable import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextDaemonService
import CmuxNextSettings
import Testing

/// The palette rows for `cmux git worktree create|apply|remove`, `cmux git checkpoint create` and
/// `cmux harness icon` (Leo, 2026-11-08: "Every conceivable possible aspect of the app"): each is a
/// palette action whose CLI stays its owner's verb, and each sends the request that verb sends.
@MainActor
struct GitAndHarnessPaletteActionsTests {
    private static let ids: [ActionID] = [
        "git.worktree.create", "git.worktree.apply", "git.worktree.remove", "git.checkpoint.create", "agent.harness.setIcon",
    ]

    @Test func eachVerbHasAPaletteRowAndKeepsItsOwnersCLIVerb() throws {
        for id in Self.ids {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id }, "\(id) is in the catalog")
            #expect(descriptor.isPaletteVisible, "\(id) is a palette row")
            #expect(descriptor.surfacePlan.cli == .exempt(.ownerVerb), "\(id): the CLI runs the owner's own verb")
        }
    }

    @Test func setIconPicksAnAgentThenAsksForTheIcon() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "agent.harness.setIcon" })
        #expect(descriptor.arguments.map(\.name) == ["id", "icon"])
        #expect(descriptor.arguments.map(\.isRequired) == [true, true], "the palette asks for both")
        #expect(descriptor.arguments.first?.suggestions?.source == ActionSuggestions.agentHarnessProfiles)
    }

    @Test func worktreeCreateSendsTheNameAndBaseGiven() {
        let request = GitRepositoryActions.Request.make("git.worktree.create", arguments: ["name": .string(" fix login "), "base": .string("main")])
        #expect(request == GitRepositoryActions.Request(operation: "git.worktree.create",
                                                         params: ["name": .string("fix login"), "base": .string("main")], localOnly: true))
        // No name: the session host picks a free one, as `cmux git worktree create` does.
        #expect(GitRepositoryActions.Request.make("git.worktree.create", arguments: ["name": .string("  ")])?.params.isEmpty == true)
    }

    @Test func removeDiscardsOnlyWhenAsked() {
        #expect(GitRepositoryActions.Request.make("git.worktree.remove", arguments: [:])?.params.isEmpty == true)
        #expect(GitRepositoryActions.Request.make("git.worktree.remove", arguments: ["discard": .bool(true)])?.params == ["discard": .bool(true)])
    }

    @Test func worktreeWritesStayOnThisMacAndACheckpointIsAManualCapture() {
        #expect(GitRepositoryActions.Request.make("git.worktree.apply", arguments: [:])?.localOnly == true)
        let checkpoint = GitRepositoryActions.Request.make("git.checkpoint.create", arguments: [:])
        #expect(checkpoint?.operation == "git.checkpoint.create")
        #expect(checkpoint?.params == ["reason": .string("manual")])
        #expect(checkpoint?.localOnly == false)
        #expect(GitRepositoryActions.Request.make("git.status", arguments: [:]) == nil)
    }

    @Test func theIconPickListsOnlyTheUsersOwnProfiles() {
        let state: CmuxNextSettings.JSONValue = ["harnesses": [
            ["id": "acme", "name": "Acme Agent", "removable": true],
            ["id": "claude", "name": "Claude Code", "removable": false],
        ]]
        #expect(AgentHarnessIconAction.profileChoices(state) == [ActionEnumCase(value: "acme", title: "Acme Agent")])
    }
}
