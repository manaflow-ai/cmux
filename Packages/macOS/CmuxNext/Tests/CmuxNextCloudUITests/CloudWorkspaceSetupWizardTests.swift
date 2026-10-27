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
    @Test func explicitConsentTransfersOnlyTheSelectedProvider() async throws {
        var moved: [CloudWorkspaceSetupWizard.Provider] = []
        try await CloudWorkspaceSetupWizard().offerCredentialSetup(machine: "paint", account: "Personal account",
            present: { _ in CmuxDialogAnswer(button: "transfer", role: .normal, values: ["claude": .bool(true)]) },
            transfer: { moved.append($0) })
        #expect(moved == [.claude])
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
