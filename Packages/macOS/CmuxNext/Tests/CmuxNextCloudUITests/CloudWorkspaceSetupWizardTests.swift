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

    /// A new Cloud workspace never asks for or moves a login: the VM's Claude and Codex reach models
    /// through the Cloud service's model route, on a personal machine and a team one alike. The
    /// dialog says so, and holds no provider check or transfer step.
    @Test(arguments: [true, false])
    func theSetupDialogNamesTheModelRouteAndOffersNoLoginStep(supportsEnvironments: Bool) {
        let spec = CloudWorkspaceSetupWizard.setupDialogSpec(supportsEnvironments: supportsEnvironments)
        #expect(spec.lines.count == 2)
        #expect(spec.lines.last?.contains("Cloud service") == true)
        #expect(spec.lines.last?.contains("No login moves from this Mac") == true)
        #expect(!spec.lines.joined().contains("setup-token"))
        #expect(spec.buttons.map(\.id) == ["cancel", "create"])
        let checks = spec.fields.filter { if case .check = $0 { return true } else { return false } }
        #expect(checks.isEmpty)
    }

    @MainActor
    @Test(arguments: [true, false])
    func accountOrTeamChangeDuringSetupRefusesTheCreationPlan(changesTeam: Bool) async throws {
        let originalUser = "user-a", originalTeam = "team-a"
        var currentUser = originalUser, currentTeam = originalTeam
        let plan = try await CloudWorkspaceSetupWizard().choosePlan(
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
        let plan = try await CloudWorkspaceSetupWizard().choosePlan(
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
        _ = try await CloudWorkspaceSetupWizard().choosePlan(scopeIsCurrent: { true },
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
