public import CmuxNextCloud
public import CmuxNextDesign
import Foundation

/// The short, person-started setup behind New Cloud Machine. The existing
/// creation flow still owns provisioning and opening the first workspace.
@MainActor
public struct CloudWorkspaceSetupWizard {
    /// Creates a wizard whose presentation and side effects are supplied by the app.
    public init() {}

    /// A retryable attempt waits until its workspace opens or the person ends it.
    public enum Readiness: Equatable, Sendable { case waiting, ready, ended }

    /// The localized destination label for an account without a selected team.
    public nonisolated static let personalAccountTitle = String(localized: "cloud.workspaceSetup.personalAccount", defaultValue: "Personal account", table: "Cloud", bundle: .module)

    /// The starting contents of a new machine.
    public nonisolated enum Source: String, Sendable, Equatable {
        case empty
        case repository
        /// One of the team's Cloud environments (cmux-next Cloud only); the choice value is `environment:<id>`.
        case environment
        /// Save a repository as a new Cloud environment and boot it (cmux-next Cloud only).
        case newEnvironment
    }

    /// One of the team's Cloud environments, as the dialog lists it.
    public nonisolated struct EnvironmentOption: Sendable, Equatable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// A new environment the wizard saves before it boots it: named after its repository.
    public nonisolated struct NewEnvironment: Sendable, Equatable {
        public var name: String
        public var repo: CloudMachineRepo
        public var setupScript: String
        public init(name: String, repo: CloudMachineRepo, setupScript: String) {
            self.name = name
            self.repo = repo
            self.setupScript = setupScript
        }
    }

    /// A choice value no source names (an `environment:` without an id, or text from elsewhere).
    public nonisolated struct UnknownChoice: Error, Equatable {
        public var value: String
    }

    private nonisolated static let environmentPrefix = "environment:"

    /// Validated creation input, without any machine or credential side effects.
    public nonisolated struct Plan: Sendable, Equatable {
        /// The chosen starting point.
        public var source: Source
        /// A repository only when the person chose the repository starting point.
        public var repository: CloudMachineRepo?
        /// The environment to boot, for ``Source/environment``.
        public var environment: String?
        /// The environment to save first, for ``Source/newEnvironment``.
        public var newEnvironment: NewEnvironment?

        public init(source: Source, repository: CloudMachineRepo? = nil, environment: String? = nil, newEnvironment: NewEnvironment? = nil) {
            self.source = source
            self.repository = repository
            self.environment = environment
            self.newEnvironment = newEnvironment
        }

        /// The existing machine creation request for this starting point. A new environment's id is
        /// set by the caller once it is saved.
        public var request: CloudMachineRequest {
            var request = CloudMachineRequest(repo: repository)
            request.environment = environment
            return request
        }

        /// The plan for a dialog choice value: `empty`, `repository`, `newEnvironment` or `environment:<id>`.
        public static func make(choice: String, repositoryText: String, setupScript: String) throws -> Plan {
            if choice.hasPrefix(CloudWorkspaceSetupWizard.environmentPrefix) {
                let id = String(choice.dropFirst(CloudWorkspaceSetupWizard.environmentPrefix.count))
                guard !id.isEmpty else { throw UnknownChoice(value: choice) }
                return Plan(source: .environment, environment: id)
            }
            guard let source = Source(rawValue: choice), source != .environment else { throw UnknownChoice(value: choice) }
            if source == .newEnvironment {
                let repo = try CloudMachineRepo.parse(repositoryText)
                let script = setupScript.trimmingCharacters(in: .whitespacesAndNewlines)
                return Plan(source: .newEnvironment, newEnvironment: NewEnvironment(name: repo.name, repo: repo, setupScript: script))
            }
            return try make(source: source, repositoryText: repositoryText)
        }

        /// Ignores stale repository text for an empty VM and validates it otherwise.
        public static func make(source: Source, repositoryText: String) throws -> Plan {
            switch source {
            case .empty:
                return Plan(source: .empty, repository: nil)
            case .repository:
                return Plan(source: .repository, repository: try CloudMachineRepo.parse(repositoryText))
            case .environment, .newEnvironment:
                throw UnknownChoice(value: source.rawValue)
            }
        }
    }

    /// Whether the selected account and API route allow personal provider setup.
    public nonisolated enum CredentialAvailability: Equatable, Sendable {
        case available
        case teamMachine
        case unsupportedCloudRoute

        /// Shared team machines never receive personal credentials through this flow.
        public static func resolve(teamID: String?, supportsFileRoute: Bool) -> CredentialAvailability {
            guard teamID == nil else { return .teamMachine }
            return supportsFileRoute ? .available : .unsupportedCloudRoute
        }
    }

    private enum Field {
        static let source = "source"
        static let repository = "repository"
        static let setupScript = "setupScript"
    }

    /// Presents the starting-point choice; dismissal has no side effects.
    /// `environments` and `supportsEnvironments`: the team's Cloud environments, on the cmux-next
    /// Cloud path only (the classic path has none and its answers never name one).
    public func choosePlan(availability: CredentialAvailability,
                           scopeIsCurrent: () -> Bool,
                           supportsRepository: Bool = true,
                           environments: [EnvironmentOption] = [],
                           supportsEnvironments: Bool = false,
                           present: (CmuxDialogSpec) async -> CmuxDialogAnswer) async throws -> Plan? {
        let answer = await present(Self.setupDialogSpec(availability: availability, supportsRepository: supportsRepository,
                                                        environments: environments, supportsEnvironments: supportsEnvironments))
        guard scopeIsCurrent(), answer.button == "create", !answer.isDismissal,
              let choice = answer.text(Field.source) else { return nil }
        let plan: Plan
        do { plan = try Plan.make(choice: choice, repositoryText: answer.text(Field.repository) ?? "", setupScript: answer.text(Field.setupScript) ?? "") }
        catch let error as CloudMachineRepo.Invalid { throw RepositoryFailure(error: error) }
        catch is UnknownChoice { return nil }
        switch plan.source {
        case .empty: return plan
        case .repository: return supportsRepository ? plan : nil
        case .environment: return supportsEnvironments && environments.contains { $0.id == plan.environment } ? plan : nil
        case .newEnvironment: return supportsEnvironments ? plan : nil
        }
    }

    private struct RepositoryFailure: LocalizedError {
        let error: CloudMachineRepo.Invalid
        var errorDescription: String? {
            switch error {
            case .unrecognized: CloudWorkspaceSetupWizardStrings.repositoryInvalid
            case .credentialsInURL: CloudWorkspaceSetupWizardStrings.repositoryCredentials
            case .invalidRef: CloudWorkspaceSetupWizardStrings.repositoryRefInvalid
            }
        }
    }

    /// The production setup dialog, also used by the native gallery.
    public static func setupDialogSpec(availability: CredentialAvailability = .available,
                                source: Source = .empty, repository: String = "", supportsRepository: Bool = true,
                                environments: [EnvironmentOption] = [], supportsEnvironments: Bool = false) -> CmuxDialogSpec {
        var options = [
            CmuxDialogOption(label: CloudWorkspaceSetupWizardStrings.emptyChoice, value: Source.empty.rawValue),
            CmuxDialogOption(label: CloudWorkspaceSetupWizardStrings.repositoryChoice, value: Source.repository.rawValue, isEnabled: supportsRepository),
        ]
        var fields: [CmuxDialogField] = []
        let summary: String
        if supportsEnvironments {
            options += environments.map { CmuxDialogOption(label: CloudWorkspaceSetupWizardStrings.environmentChoice($0.name), value: environmentPrefix + $0.id) }
            options.append(CmuxDialogOption(label: CloudWorkspaceSetupWizardStrings.newEnvironmentChoice, value: Source.newEnvironment.rawValue))
            summary = CloudWorkspaceSetupWizardStrings.environmentSummary
        } else {
            summary = supportsRepository ? CloudWorkspaceSetupWizardStrings.setupSummary : CloudWorkspaceSetupWizardStrings.emptyOnlySummary
        }
        let usable = (source == .repository && !supportsRepository) || source == .environment || (source == .newEnvironment && !supportsEnvironments) ? Source.empty : source
        fields.append(.choice(id: Field.source, label: CloudWorkspaceSetupWizardStrings.sourceLabel, options: options, selected: usable.rawValue))
        fields.append(.text(Field.repository, initial: repository, label: supportsEnvironments && !supportsRepository ? CloudWorkspaceSetupWizardStrings.newEnvironmentRepositoryLabel : CloudWorkspaceSetupWizardStrings.repositoryLabel,
                            placeholder: CloudWorkspaceSetupWizardStrings.repositoryPlaceholder))
        if supportsEnvironments {
            fields.append(.text(Field.setupScript, label: CloudWorkspaceSetupWizardStrings.setupScriptLabel, placeholder: CloudWorkspaceSetupWizardStrings.setupScriptPlaceholder))
        }
        return CmuxDialogSpec(
            title: CloudWorkspaceSetupWizardStrings.title,
            lines: [summary, CloudWorkspaceSetupWizardStrings.credentialsNote(availability)],
            fields: fields,
            buttons: [
                .cancel(CloudWorkspaceSetupWizardStrings.cancel),
                CmuxDialogButton(id: "create", title: CloudWorkspaceSetupWizardStrings.create, role: .default),
            ],
            identifier: "cmux.dialog.cloud.workspaceSetup")
    }

    /// Reveals a completed clone only while the original workspace is still active.
    public nonisolated static func shouldRevealProject(originalWorkspace: String?, currentWorkspace: String?, windowIsActive: Bool) -> Bool {
        originalWorkspace != nil && originalWorkspace == currentWorkspace && windowIsActive
    }

    /// Opens the cloned project only after bootstrap succeeds; failures retain their localized cause.
    public func finishBootstrap(_ completion: CloudMachineBootstrap.Completion,
                                openProject: (String) async throws -> Void) async throws {
        switch completion {
        case .finished(let repoPath):
            if let repoPath { try await openProject(repoPath) }
        case .failed(let reason):
            throw BootstrapFailure(errorDescription: reason)
        }
    }

    private nonisolated struct BootstrapFailure: LocalizedError {
        let errorDescription: String?
    }

    /// Identifies consent dialogs that automation must never answer.
    public static let credentialDialogIdentifier = "cmux.dialog.cloud.workspaceCredentials"

    /// Providers whose credentials the person may explicitly transfer.
    public enum Provider: Sendable, Equatable { case claude, codex }

    /// Transfers only the selected providers after an explicit, non-dismissed confirmation.
    public func offerCredentialSetup(machine: String, account: String,
                                     present: (CmuxDialogSpec) async -> CmuxDialogAnswer,
                                     transfer: (Provider) async throws -> Void) async throws {
        let answer = await present(Self.credentialDialogSpec(machine: machine, account: account))
        guard answer.button == "transfer", !answer.isDismissal else { return }
        if answer.isOn("claude") { try await transfer(.claude) }
        if answer.isOn("codex") { try await transfer(.codex) }
    }

    /// Discloses the destination, reusable Claude token and Mac-held Codex refresh token.
    public static func credentialDialogSpec(machine: String, account: String) -> CmuxDialogSpec {
        CmuxDialogSpec(
            title: CloudWorkspaceSetupWizardStrings.credentialTitle(machine),
            lines: [CloudWorkspaceSetupWizardStrings.credentialDisclosure(machine, account)],
            fields: [
                .check(id: "claude", title: CloudWorkspaceSetupWizardStrings.setupClaude, on: false),
                .check(id: "codex", title: CloudWorkspaceSetupWizardStrings.setupCodex, on: false),
            ],
            buttons: [
                CmuxDialogButton(id: "skip", title: CloudWorkspaceSetupWizardStrings.skip, role: .default),
                CmuxDialogButton(id: "transfer", title: CloudWorkspaceSetupWizardStrings.transferAndFinish, role: .normal),
            ],
            identifier: credentialDialogIdentifier)
    }

}

private enum CloudWorkspaceSetupWizardStrings {
    nonisolated static let title = String(localized: "cloud.workspaceSetup.title", defaultValue: "New Cloud Workspace", table: "Cloud", bundle: .module)
    nonisolated static let setupSummary = String(localized: "cloud.workspaceSetup.summary", defaultValue: "Start a new project on an empty VM, or clone a GitHub repository into ~/work.", table: "Cloud", bundle: .module)
    nonisolated static let emptyOnlySummary = String(localized: "cloud.workspaceSetup.emptyOnlySummary", defaultValue: "Start a new project on an empty VM. Repository setup is not available with this Cloud connection.", table: "Cloud", bundle: .module)
    nonisolated static let sourceLabel = String(localized: "cloud.workspaceSetup.sourceLabel", defaultValue: "Start with", table: "Cloud", bundle: .module)
    nonisolated static let emptyChoice = String(localized: "cloud.workspaceSetup.emptyChoice", defaultValue: "Empty VM — start a new project", table: "Cloud", bundle: .module)
    nonisolated static let repositoryChoice = String(localized: "cloud.workspaceSetup.repositoryChoice", defaultValue: "From repository", table: "Cloud", bundle: .module)
    nonisolated static let repositoryLabel = String(localized: "cloud.workspaceSetup.repositoryLabel", defaultValue: "GitHub repository (only for From repository)", table: "Cloud", bundle: .module)
    nonisolated static let repositoryPlaceholder = String(localized: "cloud.workspaceSetup.repositoryPlaceholder", defaultValue: "owner/repository or GitHub URL", table: "Cloud", bundle: .module)
    nonisolated static let create = String(localized: "cloud.workspaceSetup.create", defaultValue: "Create workspace", table: "Cloud", bundle: .module)
    nonisolated static let cancel = String(localized: "cloud.workspaceSetup.cancel", defaultValue: "Cancel", table: "Cloud", bundle: .module)
    nonisolated static let repositoryInvalid = String(localized: "cloud.workspaceSetup.repositoryInvalid", defaultValue: "Enter a GitHub repository as owner/name or a GitHub URL.", table: "Cloud", bundle: .module)
    nonisolated static let repositoryCredentials = String(localized: "cloud.workspaceSetup.repositoryCredentials", defaultValue: "Remove the username or password from the repository URL. cmux never saves URL credentials on the VM.", table: "Cloud", bundle: .module)
    nonisolated static let repositoryRefInvalid = String(localized: "cloud.workspaceSetup.repositoryRefInvalid", defaultValue: "The branch, tag, or commit name is not supported.", table: "Cloud", bundle: .module)
    nonisolated static let environmentSummary = String(localized: "cloud.workspaceSetup.environmentSummary", defaultValue: "Start empty, start in one of your environments, or save a GitHub repository as a new environment. An environment clones the repository and runs its setup; once built, new machines start from it in about a second.", table: "Cloud", bundle: .module)
    nonisolated static func environmentChoice(_ name: String) -> String {
        String(format: String(localized: "cloud.workspaceSetup.environmentChoice", defaultValue: "Environment: %@", table: "Cloud", bundle: .module), name)
    }
    nonisolated static let newEnvironmentChoice = String(localized: "cloud.workspaceSetup.newEnvironmentChoice", defaultValue: "Save a repository as an environment", table: "Cloud", bundle: .module)
    nonisolated static let newEnvironmentRepositoryLabel = String(localized: "cloud.workspaceSetup.newEnvironmentRepositoryLabel", defaultValue: "GitHub repository (only for a new environment)", table: "Cloud", bundle: .module)
    nonisolated static let setupScriptLabel = String(localized: "cloud.workspaceSetup.setupScriptLabel", defaultValue: "Setup command (optional, only for a new environment)", table: "Cloud", bundle: .module)
    nonisolated static let setupScriptPlaceholder = String(localized: "cloud.workspaceSetup.setupScriptPlaceholder", defaultValue: "bun install", table: "Cloud", bundle: .module)
    nonisolated static let skip = String(localized: "cloud.workspaceSetup.skip", defaultValue: "Skip", table: "Cloud", bundle: .module)
    nonisolated static let setupClaude = String(localized: "cloud.workspaceSetup.setupClaude", defaultValue: "Claude", table: "Cloud", bundle: .module)
    nonisolated static let setupCodex = String(localized: "cloud.workspaceSetup.setupCodex", defaultValue: "Codex", table: "Cloud", bundle: .module)
    nonisolated static let transferAndFinish = String(localized: "cloud.workspaceSetup.transferAndFinish", defaultValue: "Transfer and finish", table: "Cloud", bundle: .module)

    nonisolated static func credentialsNote(_ availability: CloudWorkspaceSetupWizard.CredentialAvailability) -> String {
        switch availability {
        case .available:
            String(localized: "cloud.workspaceSetup.credentialsAvailable", defaultValue: "Optional Claude or Codex setup happens after the VM starts and requires a separate confirmation.", table: "Cloud", bundle: .module)
        case .teamMachine:
            String(localized: "cloud.workspaceSetup.credentialsTeamUnavailable", defaultValue: "Personal provider credentials stay off shared team VMs because they share a home folder.", table: "Cloud", bundle: .module)
        case .unsupportedCloudRoute:
            String(localized: "cloud.workspaceSetup.credentialsRouteUnavailable", defaultValue: "Provider credential setup is unavailable with this Cloud connection.", table: "Cloud", bundle: .module)
        }
    }

    nonisolated static func credentialTitle(_ machine: String) -> String {
        String(format: String(localized: "cloud.workspaceSetup.credentialTitle", defaultValue: "Set up an AI provider on %@?", table: "Cloud", bundle: .module), machine)
    }

    nonisolated static func credentialDisclosure(_ machine: String, _ team: String) -> String {
        String(format: String(localized: "cloud.workspaceSetup.credentialDisclosure", defaultValue: "Claude runs claude setup-token on this Mac when needed and saves the long-lived token for later VMs. Codex reuses sign-in on this Mac; only short-lived access moves to the VM, and its refresh token stays on this Mac. Keep cmux running on this Mac to renew Codex access. The selected credential is installed on %@ for %@, replacing that provider's login for future launches. Existing sessions stay unchanged. Select one or both providers, then confirm the transfer.", table: "Cloud", bundle: .module), machine, team)
    }

}
