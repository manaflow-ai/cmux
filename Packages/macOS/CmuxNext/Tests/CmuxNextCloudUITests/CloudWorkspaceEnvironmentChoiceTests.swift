import CmuxNextCloudUI
import CmuxNextCloud
import CmuxNextDesign
import Testing
import Foundation

/// Cloud environments in New Cloud Workspace (plans/cmux-next/cloud-environments-DESIGN.md §5): on the
/// cmux-next Cloud path the person picks one of the team's environments, or saves a repository as a
/// new environment; the classic `/api/vm` path keeps its dialog.
@Suite("Cloud workspace environment choice")
struct CloudWorkspaceEnvironmentChoiceTests {
    private let environments = [CloudWorkspaceSetupWizard.EnvironmentOption(id: "env_00000000000000000001", name: "web")]

    @Test func pickingAnEnvironmentBootsItAndNeedsNoRepository() throws {
        let plan = try CloudWorkspaceSetupWizard.Plan.make(choice: "environment:env_00000000000000000001", repositoryText: "stale text", setupScript: "")
        #expect(plan.source == .environment)
        #expect(plan.environment == "env_00000000000000000001")
        #expect(plan.repository == nil && plan.newEnvironment == nil)
        #expect(plan.request.environment == "env_00000000000000000001")
        // The cmux-next create accepts only default requests: an environment boot stays one.
        #expect(plan.request.isDefault)
    }

    @Test func savingARepositoryAsAnEnvironmentNamesItAfterTheRepository() throws {
        let plan = try CloudWorkspaceSetupWizard.Plan.make(choice: "newEnvironment", repositoryText: "https://github.com/octo/paint/tree/main", setupScript: "  bun install  ")
        #expect(plan.source == .newEnvironment)
        #expect(plan.newEnvironment == .init(name: "paint", repo: CloudMachineRepo(owner: "octo", name: "paint", ref: "main"), setupScript: "bun install"))
        #expect(plan.environment == nil && plan.repository == nil)
        #expect(plan.request.isDefault)
    }

    @Test func savingAnEnvironmentStillChecksTheRepository() {
        #expect(throws: CloudMachineRepo.Invalid.credentialsInURL) {
            try CloudWorkspaceSetupWizard.Plan.make(choice: "newEnvironment", repositoryText: "https://u:p@github.com/octo/paint", setupScript: "")
        }
    }

    @Test func theOldChoicesStillParse() throws {
        #expect(try CloudWorkspaceSetupWizard.Plan.make(choice: "empty", repositoryText: "", setupScript: "").source == .empty)
        #expect(try CloudWorkspaceSetupWizard.Plan.make(choice: "repository", repositoryText: "octo/paint", setupScript: "").repository?.spec == "octo/paint")
        #expect(throws: CloudWorkspaceSetupWizard.UnknownChoice.self) {
            try CloudWorkspaceSetupWizard.Plan.make(choice: "environment:", repositoryText: "", setupScript: "")
        }
    }

    @Test func theCmuxNextDialogListsEnvironmentsAndTheSaveChoiceAndTheClassicOneDoesNot() {
        let next = CloudWorkspaceSetupWizard.setupDialogSpec(supportsRepository: false, environments: environments, supportsEnvironments: true)
        let classic = CloudWorkspaceSetupWizard.setupDialogSpec(supportsRepository: true)
        #expect(Self.choices(next).contains("environment:env_00000000000000000001"))
        #expect(Self.choices(next).contains("newEnvironment"))
        #expect(Self.fieldIDs(next).contains("setupScript"))
        #expect(!Self.choices(classic).contains("newEnvironment"))
        #expect(!Self.choices(classic).contains { $0.hasPrefix("environment:") })
        #expect(!Self.fieldIDs(classic).contains("setupScript"))
    }

    @MainActor
    @Test func choosingAnEnvironmentInTheDialogReturnsItsPlan() async throws {
        let plan = try await CloudWorkspaceSetupWizard().choosePlan(availability: .unsupportedCloudRoute, scopeIsCurrent: { true },
            supportsRepository: false, environments: environments, supportsEnvironments: true,
            present: { _ in CmuxDialogAnswer(button: "create", role: .default, values: ["source": .text("environment:env_00000000000000000001")]) })
        #expect(plan?.environment == "env_00000000000000000001")
    }

    @MainActor
    @Test func anEnvironmentAnswerOnTheClassicPathIsRefused() async throws {
        let plan = try await CloudWorkspaceSetupWizard().choosePlan(availability: .available, scopeIsCurrent: { true },
            present: { _ in CmuxDialogAnswer(button: "create", role: .default, values: ["source": .text("newEnvironment"), "repository": .text("octo/paint")]) })
        #expect(plan == nil)
    }

    private static func choices(_ spec: CmuxDialogSpec) -> [String] {
        spec.fields.flatMap { field -> [String] in
            if case .choice(_, _, let options, _) = field { return options.map(\.value) }
            return []
        }
    }

    private static func fieldIDs(_ spec: CmuxDialogSpec) -> [String] {
        spec.fields.compactMap(\.id)
    }
}
