import CmuxNextCloudUI
import CmuxNextCloud
import CmuxNextDesign
import Testing
import Foundation

@Suite("Cloud workspace setup")
struct CloudWorkspaceSetupWizardTests {
    @Test func emptyVMStartsWithoutRepositoryEvenWhenTheFieldHasStaleText() throws {
        let plan = try CloudWorkspaceSetupWizard.Plan.make(source: .empty, repositoryText: "not a repository")

        #expect(plan.source == .empty)
        #expect(plan.repository == nil)
        #expect(plan.request.isDefault)
    }

    @Test func repositoryChoiceBuildsACloneRequestForTheSelectedRef() throws {
        let plan = try CloudWorkspaceSetupWizard.Plan.make(source: .repository,
                                                           repositoryText: "https://github.com/octo/paint/tree/fix/brush")

        #expect(plan.source == .repository)
        #expect(plan.repository?.spec == "octo/paint@fix/brush")
        #expect(plan.request.repo == plan.repository)
        #expect(!plan.request.isDefault)
    }

    @Test func repositoryChoiceRejectsCredentialsEmbeddedInTheURL() {
        #expect(throws: CloudMachineRepo.Invalid.credentialsInURL) {
            try CloudWorkspaceSetupWizard.Plan.make(source: .repository,
                                                   repositoryText: "https://user:secret@github.com/octo/paint")
        }
    }

    @Test(arguments: [
        (nil, true, CloudWorkspaceSetupWizard.CredentialAvailability.available),
        ("team-1", true, .teamMachine),
        (nil, false, .unsupportedCloudRoute),
    ])
    func providerSetupAvailabilityFollowsAccountScopeAndFileRoute(
        teamID: String?, supportsFileRoute: Bool, expected: CloudWorkspaceSetupWizard.CredentialAvailability
    ) {
        #expect(CloudWorkspaceSetupWizard.CredentialAvailability.resolve(teamID: teamID, supportsFileRoute: supportsFileRoute) == expected)
    }

    /// A build that does not copy the Mac's login points a personal VM at its own sign-in, not at
    /// the connection; a team VM keeps its own note.
    @Test func aBuildThatDoesNotPassTheLoginSaysToSignInOnTheMachine() {
        typealias A = CloudWorkspaceSetupWizard.CredentialAvailability
        #expect(A.resolve(teamID: nil, supportsFileRoute: true, passesLogin: false) == .signInOnMachine)
        #expect(A.resolve(teamID: "team-1", supportsFileRoute: true, passesLogin: false) == .teamMachine)
    }

    @MainActor
    @Test(arguments: [true, false])
    func accountOrTeamChangeDuringSetupRefusesTheCreationPlan(changesTeam: Bool) async throws {
        let originalUser = "user-a", originalTeam = "team-a"
        var currentUser = originalUser, currentTeam = originalTeam
        let plan = try await CloudWorkspaceSetupWizard().choosePlan(availability: .teamMachine,
            scopeIsCurrent: { currentUser == originalUser && currentTeam == originalTeam },
            present: { _ in
                if changesTeam { currentTeam = "team-b" } else { currentUser = "user-b" }
                return CmuxDialogAnswer(button: "create", role: .default, values: ["source": .text("empty")])
            })
        #expect(plan == nil)
    }

    @MainActor
    @Test func unsupportedRouteDisablesRepositoryAndRejectsAStaleRepositoryAnswer() async throws {
        let spec = CloudWorkspaceSetupWizard.setupDialogSpec(supportsRepository: false)
        guard case .choice(_, _, let options, let selected) = spec.fields[0] else {
            Issue.record("Missing source choice")
            return
        }
        #expect(selected == "empty")
        #expect(options.first { $0.value == "repository" }?.isEnabled == false)
        let plan = try await CloudWorkspaceSetupWizard().choosePlan(availability: .unsupportedCloudRoute,
            scopeIsCurrent: { true }, supportsRepository: false,
            present: { _ in CmuxDialogAnswer(button: "create", role: .default,
                values: ["source": .text("repository"), "repository": .text("octo/paint")]) })
        #expect(plan == nil)
    }

    /// New Cloud Machine from a chat offers the chat's own repository (its pushed branch), and
    /// nothing on a route that cannot clone.
    @MainActor
    @Test(arguments: [true, false])
    func aChatsRepositoryIsTheSuggestedStartingPoint(supportsRepository: Bool) async throws {
        var shown: CmuxDialogSpec?
        _ = try await CloudWorkspaceSetupWizard().choosePlan(availability: .available, scopeIsCurrent: { true },
            supportsRepository: supportsRepository, suggested: CloudMachineRepo(owner: "octo", name: "paint", ref: "fix/brush"),
            present: { spec in shown = spec; return CmuxDialogAnswer(button: "cancel", role: .cancel) })
        let spec = try #require(shown)
        guard case .choice(_, _, _, let selected) = spec.fields[0], case .text(_, _, let initial, _, _) = spec.fields[1] else {
            Issue.record("Missing source choice or repository field")
            return
        }
        #expect(selected == (supportsRepository ? "repository" : "empty"))
        #expect(initial == (supportsRepository ? "octo/paint@fix/brush" : ""))
    }

    @Test(arguments: [("original", true, true), ("other", true, false), ("original", false, false)])
    func completedCloneOnlyRevealsInTheUnchangedActiveWorkspace(current: String, active: Bool, expected: Bool) {
        #expect(CloudWorkspaceSetupWizard.shouldRevealProject(originalWorkspace: "original",
            currentWorkspace: current, windowIsActive: active) == expected)
    }

    @MainActor
    @Test(arguments: ["skip", "cancel", "transfer"])
    func noCredentialMovesWithoutAnExplicitProviderSelection(button: String) async throws {
        var moved: [CloudWorkspaceSetupWizard.Provider] = []
        try await CloudWorkspaceSetupWizard().offerCredentialSetup(machine: "paint", account: "Personal account",
            present: { _ in CmuxDialogAnswer(button: button, role: .normal) },
            transfer: { moved.append($0) })
        #expect(moved.isEmpty)
    }

    @MainActor
    @Test func dismissedConsentNeverTransfersEvenWhenProvidersWereSelected() async throws {
        var moved: [CloudWorkspaceSetupWizard.Provider] = []
        try await CloudWorkspaceSetupWizard().offerCredentialSetup(machine: "paint", account: "Personal account",
            present: { _ in CmuxDialogAnswer(button: "transfer", role: .normal,
                                            values: ["claude": .bool(true), "codex": .bool(true)], isDismissal: true) },
            transfer: { moved.append($0) })
        #expect(moved.isEmpty)
    }

    @MainActor
    @Test(arguments: [CloudWorkspaceSetupWizard.Provider.claude, .codex])
    func explicitConsentTransfersOnlyTheSelectedProvider(provider: CloudWorkspaceSetupWizard.Provider) async throws {
        var moved: [CloudWorkspaceSetupWizard.Provider] = []
        try await CloudWorkspaceSetupWizard().offerCredentialSetup(machine: "paint", account: "Personal account",
            present: { _ in CmuxDialogAnswer(button: "transfer", role: .normal, values: [provider == .claude ? "claude" : "codex": .bool(true)]) },
            transfer: { moved.append($0) })
        #expect(moved == [provider])
    }


    @MainActor
    @Test func completedCloneOpensItsAbsoluteProjectDirectory() async throws {
        var opened: [String] = []
        try await CloudWorkspaceSetupWizard().finishBootstrap(.finished(repoPath: "/workspace/paint")) {
            opened.append($0)
        }
        #expect(opened == ["/workspace/paint"])
    }

    @MainActor
    @Test func completionWithoutARepositoryDoesNotCreateAnotherWorkspace() async throws {
        var opened: [String] = []
        try await CloudWorkspaceSetupWizard().finishBootstrap(.finished(repoPath: nil)) { opened.append($0) }
        #expect(opened.isEmpty)
    }

    @MainActor
    @Test func cloneFailureKeepsItsCauseAndDoesNotOpenAProject() async throws {
        var opened: [String] = []
        let reason = "This repository needs GitHub access."
        do {
            try await CloudWorkspaceSetupWizard().finishBootstrap(.failed(reason: reason)) { opened.append($0) }
            Issue.record("Failed clone was treated as ready")
        } catch {
            #expect(error.localizedDescription == reason)
        }
        #expect(opened.isEmpty)
    }

}
