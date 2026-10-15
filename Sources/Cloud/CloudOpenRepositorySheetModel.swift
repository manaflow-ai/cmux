import CmuxCloud
import CmuxFoundation
import Foundation
import Observation

/// State behind "Open Repository in Cloud…": the repository field and its validation
/// (``CloudOpenRepositoryReference``, the rules `cmux vm clone` uses), the optional
/// agent and first task, whether Cloud Secrets holds a GitHub token for the repository,
/// and the one-click "Use my GitHub CLI login". Run hands a
/// ``CloudOpenRepositoryCommand`` to the presenter, which types it into a terminal.
/// Every side effect is injected so tests drive the model without a vault, `gh`, or a
/// window.
@MainActor
@Observable
final class CloudOpenRepositorySheetModel {
    typealias Agent = CloudOpenRepositoryCommand.Agent

    /// Which scopes of Cloud Secrets hold `GH_TOKEN` or `GITHUB_TOKEN`. Machine-scoped
    /// tokens do not count: which machine `vm clone` picks is decided later.
    struct GitTokenCoverage: Equatable {
        var everyMachine = false
        var projectKeys: Set<String> = []

        func covers(projectKey: String) -> Bool {
            everyMachine || projectKeys.contains(projectKey)
        }

        init(everyMachine: Bool = false, projectKeys: Set<String> = []) {
            self.everyMachine = everyMachine
            self.projectKeys = projectKeys
        }

        /// From vault records: names only, never a value.
        init(records: [CloudSecretRecord]) {
            for record in records where CloudSecretsService.gitTokenNames.contains(record.name) {
                switch record.scope {
                case .all: everyMachine = true
                case .project(let key): projectKeys.insert(key)
                case .machine: break
                }
            }
        }
    }

    struct Backend {
        /// Reads which scopes hold a GitHub token.
        var loadGitTokenCoverage: @MainActor () async -> GitTokenCoverage
        /// `gh auth token` through a pipe; nil when gh is missing or signed out.
        var readGitHubCLIToken: @Sendable () async -> String?
        /// Stores the token as GH_TOKEN for every machine.
        var storeGitHubToken: @MainActor (String) async throws -> Void
        /// Opens the Cloud Secrets sheet.
        var openSecrets: @MainActor () -> Void
    }

    enum TokenState: Equatable {
        /// Cloud Secrets not read yet: no offer, so it never flashes.
        case unknown
        /// Read; ``GitTokenCoverage`` decides whether the offer shows.
        case idle
        case readingGitHubCLI
        /// Stored from the GitHub CLI during this sheet.
        case stored
        case failed(String)
    }

    var repositoryText: String
    var agent: Agent?
    var prompt: String
    private(set) var tokenState: TokenState = .unknown
    private(set) var coverage = GitTokenCoverage()
    private(set) var runError: String?

    /// Called with the command on Run; returns false when the terminal could not open.
    var onRun: (@MainActor (CloudOpenRepositoryCommand) -> Bool)?
    var onFinished: (@MainActor () -> Void)?

    private let backend: Backend

    init(repository: String = "", agent: Agent? = nil, prompt: String? = nil, backend: Backend) {
        self.repositoryText = repository
        self.agent = agent
        self.prompt = prompt ?? ""
        self.backend = backend
    }

    // MARK: Derived

    /// The parsed field, or why it was refused. Empty is `.failure(.empty)`.
    var validation: Result<CloudOpenRepositoryReference, CloudOpenRepositoryReferenceError> {
        if CloudOpenRepositoryCommand.containsControlCharacters(repositoryText) { return .failure(.unrecognized) }
        return CloudOpenRepositoryReference.parse(repositoryText)
    }

    var reference: CloudOpenRepositoryReference? {
        if case .success(let reference) = validation { return reference }
        return nil
    }

    /// The message under the field. Nothing for an empty field.
    var validationMessage: String? {
        guard case .failure(let error) = validation else { return nil }
        return Self.message(for: error)
    }

    var command: CloudOpenRepositoryCommand? {
        reference.map { CloudOpenRepositoryCommand(reference: $0, agent: agent, prompt: prompt) }
    }

    var canRun: Bool { command != nil }

    /// Offer "Use my GitHub CLI login" when the repository is on GitHub and no token
    /// covers it. Public repositories clone without one, so this is an offer, not a gate.
    var showsGitHubTokenOffer: Bool {
        guard let reference, reference.isGitHub else { return false }
        switch tokenState {
        case .unknown: return false
        case .idle: return !coverage.covers(projectKey: reference.projectKey)
        // Stay up while working, after a failure, and to confirm the save.
        case .readingGitHubCLI, .stored, .failed: return true
        }
    }

    // MARK: Actions

    func load() async {
        let loaded = await backend.loadGitTokenCoverage()
        coverage.everyMachine = coverage.everyMachine || loaded.everyMachine
        coverage.projectKeys.formUnion(loaded.projectKeys)
        if tokenState == .unknown { tokenState = .idle }
    }

    func useGitHubCLILogin() async {
        guard tokenState != .readingGitHubCLI else { return }
        tokenState = .readingGitHubCLI
        guard let token = await backend.readGitHubCLIToken(), Self.isPlausibleToken(token) else {
            tokenState = .failed(String(
                localized: "cloudOpenRepository.token.ghFailed",
                defaultValue: "The GitHub CLI did not return a token. Run `gh auth login` in a terminal, then try again."
            ))
            return
        }
        do {
            try await backend.storeGitHubToken(token)
            coverage.everyMachine = true
            tokenState = .stored
        } catch {
            tokenState = .failed(String(
                localized: "cloudOpenRepository.token.storeFailed",
                defaultValue: "The token could not be saved to Cloud Secrets. Open Cloud Secrets to add GH_TOKEN by hand."
            ))
        }
    }

    func openSecrets() { backend.openSecrets() }

    func run() {
        guard let command else { return }
        runError = nil
        if onRun?(command) == false {
            runError = String(
                localized: "cloudOpenRepository.run.failed",
                defaultValue: "cmux could not open a terminal for the clone. Open a terminal and run the command above."
            )
            return
        }
        onFinished?()
    }

    func cancel() { onFinished?() }

    // MARK: Helpers

    /// One line of printable ASCII, the shape every GitHub token has.
    nonisolated static func isPlausibleToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 1_024
            && token.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }

    nonisolated static func message(for error: CloudOpenRepositoryReferenceError) -> String? {
        switch error {
        case .empty:
            return nil
        case .unrecognized:
            return String(
                localized: "cloudOpenRepository.error.unrecognized",
                defaultValue: "Not a repository. Use owner/repo, a github.com link, git@host:path.git, or an https git URL."
            )
        case .credentialsInURL:
            return String(
                localized: "cloudOpenRepository.error.credentials",
                defaultValue: "This link carries a password or token. Remove it; cmux uses the GitHub token in Cloud Secrets instead."
            )
        case .invalidBranch:
            return String(
                localized: "cloudOpenRepository.error.branch",
                defaultValue: "The branch in this link is not a valid branch name."
            )
        }
    }
}
