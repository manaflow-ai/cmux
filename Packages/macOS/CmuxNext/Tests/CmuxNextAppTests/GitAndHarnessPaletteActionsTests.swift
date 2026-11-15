import AppKit
@testable import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
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

    @Test func removeAsksFirstBecauseItDeletesTheWorktree() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "git.worktree.remove" })
        #expect(descriptor.isDestructive, "the palette asks first; a script must pass confirm, discard or not")
        #expect(descriptor.arguments.map(\.name) == ["discard", ActionArgument.confirmName])
    }

    /// Review F1: the destructive flag alone ran it unasked, since the presenter had no question for
    /// it. A palette run now reaches the presenter, which has a question with or without `discard`
    /// (a plain remove deletes ignored files such as .env), and a script without `confirm` is refused.
    @Test func removeAsksItsQuestionBeforeItRuns() async {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        var presented: [ActionID] = []
        services.registry.confirmationPresenter = { id, _, _ in presented.append(id) }
        _ = services.registry.perform("git.worktree.remove", invocation: ActionInvocation())
        #expect(presented == ["git.worktree.remove"], "the palette run did not ask")

        let folder: [String: ActionValue] = [GitRepositoryActions.pinnedPathName: .string("/repo/worktree-a")]
        let plain = await DestructiveConfirmation.prompt(for: "git.worktree.remove", ActionInvocation(arguments: folder), services)
        let discarding = await DestructiveConfirmation.prompt(
            for: "git.worktree.remove", ActionInvocation(arguments: folder.merging(["discard": .bool(true)]) { $1 }), services)
        // Review (codex) F2: no folder pinned (the tab has none) asks nothing, so the run refuses at once
        // instead of resolving a folder after the question.
        #expect(await DestructiveConfirmation.prompt(for: "git.worktree.remove", ActionInvocation(), services) == nil)
        #expect(plain != nil, "no question, so the presenter runs it unasked")
        #expect(discarding != nil)
        #expect(plain?.body != discarding?.body, "discarding says it deletes uncommitted changes too")
        #expect(plain?.returnConfirms == false, "Return must not remove a worktree")

        let reason = services.registry.capturingRefusal {
            _ = services.registry.perform("git.worktree.remove", invocation: ActionInvocation(origin: .cli))
        }
        #expect(reason == ActionRegistry.confirmationRequiredReason(for: "git.worktree.remove"))
    }

    /// Review (codex) F1: the confirmed run re-read the selected tab's folder, so a tab switch or a
    /// `cd` while the question was up removed a different worktree. The question pins the folder it
    /// asked about; a confirmed run whose tab is now elsewhere is refused before anything is sent.
    @Test func aConfirmedRemoveRefusesWhenItsTabLeftTheFolderItAskedAbout() {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        let link = AgentPaneGitLink(daemon: DaemonService())
        GitRepositoryActions(place: { _ in GitRepositoryActions.Place(link: link, cwd: "/repo/worktree-b") }, announce: { _ in }).bind(into: registry)
        let invocation = ActionInvocation(arguments: [GitRepositoryActions.pinnedPathName: .string("/repo/worktree-a")]).confirmed()
        let reason = registry.capturingRefusal { _ = registry.perform("git.worktree.remove", invocation: invocation) }
        #expect(reason == GitRepositoryStrings.folderChanged)

        // Review (codex) at d86de003: an in-app remove that pinned nothing (its tab had no folder at the
        // press) runs unasked; a folder that turned up before it runs must not be removed. A script's
        // run, which passes confirm itself, resolves its tab when it runs and is not refused this way.
        let unpinned = registry.capturingRefusal { _ = registry.perform("git.worktree.remove", invocation: ActionInvocation().confirmed()) }
        #expect(unpinned == GitRepositoryStrings.noFolder)

        // The pin names the tab and machine too, so the confirmed run resolves that tab, not the selected one.
        let tab = ActionTargetRef(kind: .tab, id: "tab-a")
        let place = GitRepositoryActions.Place(link: link, cwd: "/repo/worktree-a", tab: tab, machineID: "local")
        let pinned = GitRepositoryActions.pinned(ActionInvocation(arguments: ["discard": .bool(true)]), at: place)
        #expect(pinned?.target == tab)
        #expect(pinned?.targetMachineID == "local")
        #expect(pinned?[GitRepositoryActions.pinnedPathName]?.stringValue == "/repo/worktree-a")
        #expect(pinned?["discard"]?.boolValue == true, "the question's own arguments stay")
        #expect(GitRepositoryActions.pinned(ActionInvocation(), at: nil) == nil, "no tab folder: no pin, the run refuses as before")
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

    /// #38631 review follow-up: before the harness list is read, the pick awaits a read instead of
    /// answering the empty list (the palette froze it, so the picker stayed empty until reopened).
    @Test func theIconPickReadsAListNotReadYetBeforeItAnswers() async throws {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        var state: CmuxNextSettings.JSONValue = ["status": "loading", "harnesses": []]
        var reads = 0
        AgentHarnessIconAction(setIcon: { _, _ in }, state: { state }, refresh: {
            reads += 1
            state = ["status": "ready", "harnesses": [["id": "acme", "name": "Acme Agent", "removable": true]]]
        }, failure: { _ in "" }).bind(into: registry)
        #expect(registry.argumentSuggestions?(ActionSuggestions.agentHarnessProfiles) == [], "nothing read yet")
        let load = try #require(registry.argumentSuggestionsLoad?(ActionSuggestions.agentHarnessProfiles))
        #expect(await load() == [ActionEnumCase(value: "acme", title: "Acme Agent")])
        #expect(reads == 1)
        #expect(registry.argumentSuggestionsLoad?(ActionSuggestions.agentHarnessProfiles) == nil, "read: the list shows at once")
        #expect(registry.argumentSuggestionsLoad?("other.source") == nil)
    }

    @Test func theIconPickListsOnlyTheUsersOwnProfiles() {
        let state: CmuxNextSettings.JSONValue = ["harnesses": [
            ["id": "acme", "name": "Acme Agent", "removable": true],
            ["id": "claude", "name": "Claude Code", "removable": false],
        ]]
        #expect(AgentHarnessIconAction.profileChoices(state) == [ActionEnumCase(value: "acme", title: "Acme Agent")])
    }
}
