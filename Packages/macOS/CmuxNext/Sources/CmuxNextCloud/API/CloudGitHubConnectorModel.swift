import Foundation
import Observation

/// Main-actor state for the reusable Connect GitHub card and repository picker.
///
/// `retryRepository` is deliberately the only retry callback. The caller owns machine creation;
/// returning from GitHub therefore cannot repeat it. Call `resumeAfterInstall()` from the app's
/// browser-return callback after `connect()` has opened the install page.
@MainActor @Observable public final class CloudGitHubConnectorModel {
    /// The latest GitHub connector state, or nil before the first refresh.
    public private(set) var state: CloudConnectorState?
    /// Repositories shown by the picker, accumulated across connector pages.
    public private(set) var repositories: [CloudGitHubRepository] = []
    /// The next opaque cursor from C1, if another page is available.
    public private(set) var repositoryCursor: String?
    /// True while the state endpoint is in flight.
    public private(set) var isRefreshing = false
    /// True while a repository page is in flight.
    public private(set) var isLoadingRepositories = false
    /// The latest classified error. A new successful request clears it.
    public private(set) var error: CloudGitHubConnectorClientError?

    @ObservationIgnored private let client: any CloudGitHubConnectorClient
    @ObservationIgnored private let openInstallURL: @MainActor @Sendable (URL) async throws -> Void
    @ObservationIgnored private let retryRepository: @MainActor @Sendable () async -> Void
    @ObservationIgnored private let scopeIsCurrent: @MainActor @Sendable () -> Bool
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var repositoryGeneration = 0
    @ObservationIgnored private var repositoryRequestID = 0
    @ObservationIgnored private var installReturnPending = false
    @ObservationIgnored private var connectInFlight = false
    @ObservationIgnored private var installResumeInFlight = false

    /// Creates state without performing network work or opening a browser.
    public init(client: any CloudGitHubConnectorClient,
                openInstallURL: @escaping @MainActor @Sendable (URL) async throws -> Void,
                retryRepository: @escaping @MainActor @Sendable () async -> Void,
                scopeIsCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) {
        self.client = client
        self.openInstallURL = openInstallURL
        self.retryRepository = retryRepository
        self.scopeIsCurrent = scopeIsCurrent
    }

    /// Refreshes only connector state. Callers can use the result to choose card copy.
    @discardableResult
    public func refresh() async -> CloudConnectorState? {
        refreshGeneration += 1
        let generation = refreshGeneration
        guard scopeIsCurrent() else { invalidateScope(); return nil }
        isRefreshing = true
        defer {
            if generation == refreshGeneration { isRefreshing = false }
        }
        do {
            let statuses = try await client.connectorStatuses()
            guard !Task.isCancelled, generation == refreshGeneration, scopeIsCurrent() else {
                if !scopeIsCurrent() { invalidateScope() }
                return nil
            }
            let next = statuses.first { $0.provider.caseInsensitiveCompare("github") == .orderedSame }?.state
            state = next
            if next != .installed { repositories = []; repositoryCursor = nil }
            error = nil
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration, scopeIsCurrent() else {
                if !scopeIsCurrent() { invalidateScope() }
                return nil
            }
            state = nil
            repositories = []; repositoryCursor = nil
            error = Self.classify(error)
        }
        return state
    }

    /// Fetches the first repository page for `query`, replacing any previous query's results.
    public func searchRepositories(_ query: String) async {
        guard scopeIsCurrent() else { invalidateScope(); return }
        repositoryGeneration += 1
        let generation = repositoryGeneration
        repositories = []
        repositoryCursor = nil
        await loadRepositoryPage(query: query, cursor: nil, generation: generation)
    }

    /// Fetches the next page for the current query. A missing cursor is a no-op.
    public func loadMoreRepositories(query: String) async {
        guard scopeIsCurrent() else { invalidateScope(); return }
        guard let cursor = repositoryCursor else { return }
        await loadRepositoryPage(query: query, cursor: cursor, generation: repositoryGeneration)
    }

    /// Opens C1's GitHub App install page. The URL is checked before it reaches the browser.
    /// The caller invokes `resumeAfterInstall()` when the app receives the browser return.
    public func connect() async {
        guard scopeIsCurrent(), !connectInFlight else { return }
        // A new click starts a fresh browser handoff, even if the previous page was dismissed.
        installReturnPending = false
        connectInFlight = true
        defer { connectInFlight = false }
        do {
            let url = try await client.installURL()
            guard !Task.isCancelled, scopeIsCurrent() else { invalidateScope(); return }
            guard Self.isSafeInstallURL(url) else {
                error = .requestFailed
                return
            }
            try await openInstallURL(url)
            guard !Task.isCancelled, scopeIsCurrent() else { invalidateScope(); return }
            installReturnPending = true
            error = nil
        } catch {
            guard !Task.isCancelled, scopeIsCurrent() else { invalidateScope(); return }
            error = Self.classify(error)
        }
    }

    /// Completes a browser return by refreshing state and retrying only the repository step once.
    /// A return that did not follow a successful `connect()` is ignored.
    public func resumeAfterInstall() async {
        guard scopeIsCurrent(), installReturnPending, !installResumeInFlight else { return }
        installResumeInFlight = true
        defer { installResumeInFlight = false }
        let refreshStart = refreshGeneration
        let refreshed = await refresh()
        // Keep the pending return until a fresh installed response arrives. This handles a user
        // returning before accepting the GitHub install, and a transient offline response.
        guard !Task.isCancelled, scopeIsCurrent(), refreshGeneration == refreshStart + 1, error == nil, refreshed == .installed else { return }
        installReturnPending = false
        await retryRepository()
    }

    /// Validates an install URL before opening it in the system browser.
    public nonisolated static func isSafeInstallURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.port == nil, components.user == nil, components.password == nil,
              components.fragment == nil else { return false }
        if let items = components.queryItems,
           items.contains(where: { !["state", "installation_id", "setup_action"].contains($0.name) }) {
            return false
        }
        let path = components.path
        guard !path.contains("//") else { return false }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        guard parts.count >= 2 else { return false }
        if parts.first == "apps" {
            return parts.count >= 4 && parts[2] == "installations"
        }
        return parts.first == "installations" && parts.count <= 3
    }

    private func loadRepositoryPage(query: String, cursor: String?, generation: Int) async {
        guard scopeIsCurrent() else { invalidateScope(); return }
        repositoryRequestID += 1
        let requestID = repositoryRequestID
        isLoadingRepositories = true
        defer {
            if requestID == repositoryRequestID { isLoadingRepositories = false }
        }
        do {
            let page = try await client.repositories(query: query, cursor: cursor)
            guard !Task.isCancelled, scopeIsCurrent(), generation == repositoryGeneration, requestID == repositoryRequestID else {
                if !scopeIsCurrent() { invalidateScope() }
                return
            }
            var seen = Set(repositories.map(\.id))
            for repo in page.repos where seen.insert(repo.id).inserted { repositories.append(repo) }
            repositoryCursor = page.cursor
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard scopeIsCurrent(), generation == repositoryGeneration, requestID == repositoryRequestID else {
                if !scopeIsCurrent() { invalidateScope() }
                return
            }
            error = Self.classify(error)
        }
    }

    private func invalidateScope() {
        state = nil
        repositories = []
        repositoryCursor = nil
        error = nil
        installReturnPending = false
    }

    private nonisolated static func classify(_ error: Error) -> CloudGitHubConnectorClientError {
        if let typed = error as? CloudGitHubConnectorClientError { return typed }
        if let url = error as? URLError { return CloudGitHubConnectorClientError.classify(transport: url) }
        return .requestFailed
    }
}

