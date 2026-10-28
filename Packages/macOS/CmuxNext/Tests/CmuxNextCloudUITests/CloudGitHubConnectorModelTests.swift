import Foundation
import Testing
@testable import CmuxNextCloud

@Suite("Cloud GitHub connector")
struct CloudGitHubConnectorModelTests {
    @Test(arguments: [
        ("https://github.com/apps/cmux/installations/new", true),
        ("https://github.com/installations/123?state=abc", true),
        ("http://github.com/apps/cmux/installations/new", false),
        ("https://evil.example/apps/cmux/installations/new", false),
        ("https://user:pass@github.com/apps/cmux/installations/new", false),
        ("https://github.com:443/apps/cmux/installations/new", false),
        ("https://github.com/apps/cmux/installations/new?token=secret", false),
    ])
    func installURLIsAllowlisted(raw: String, expected: Bool) throws {
        #expect(CloudGitHubConnectorModel.isSafeInstallURL(try #require(URL(string: raw))) == expected)
    }

    @MainActor
    @Test func refreshReadsOnlyGithubConnectorState() async {
        let fake = FakeConnector(statuses: [
            [CloudConnectorStatus(provider: "gitlab", state: .installed),
             CloudConnectorStatus(provider: "github", state: .needsAuth)]
        ])
        let model = CloudGitHubConnectorModel(client: fake, openInstallURL: { _ in }, retryRepository: {})
        #expect(await model.refresh() == .needsAuth)
        #expect(model.error == nil)
    }

    @MainActor
    @Test func browserReturnRetriesOnlyRepoAfterInstalled() async {
        let fake = FakeConnector(
            statuses: [
                [CloudConnectorStatus(provider: "github", state: .needsAuth)],
                [CloudConnectorStatus(provider: "github", state: .installed)]
            ],
            install: URL(string: "https://github.com/apps/cmux/installations/new") ?? URL(fileURLWithPath: "/"))
        let recorder = Recorder()
        let model = CloudGitHubConnectorModel(client: fake,
            openInstallURL: { url in await recorder.open(url) },
            retryRepository: { await recorder.retry() })
        await model.connect()
        #expect(await recorder.urls().count == 1)
        await model.resumeAfterInstall()
        await model.resumeAfterInstall()
        #expect(await recorder.retries == 1)
    }

    @MainActor
    @Test func failedInstallDoesNotOpenOrRetry() async {
        let fake = FakeConnector(install: URL(string: "https://evil.example/install") ?? URL(fileURLWithPath: "/"))
        let recorder = Recorder()
        let model = CloudGitHubConnectorModel(client: fake,
            openInstallURL: { url in await recorder.open(url) },
            retryRepository: { await recorder.retry() })
        await model.connect()
        await model.resumeAfterInstall()
        #expect(model.error == .requestFailed)
        #expect(await recorder.urls().isEmpty)
        #expect(await recorder.retries == 0)
    }

    @MainActor
    @Test func repositoryPagesAccumulateAndDeduplicate() async {
        let first = CloudGitHubRepository(owner: "acme", name: "app", isPrivate: true, defaultBranch: "main")
        let second = CloudGitHubRepository(owner: "acme", name: "docs", isPrivate: false, defaultBranch: "trunk")
        let fake = FakeConnector(pages: [
            "": CloudGitHubRepositoryPage(repos: [first], cursor: "next"),
            "next": CloudGitHubRepositoryPage(repos: [first, second])
        ])
        let model = CloudGitHubConnectorModel(client: fake, openInstallURL: { _ in }, retryRepository: {})
        await model.searchRepositories("")
        await model.loadMoreRepositories(query: "")
        #expect(model.repositories.map(\.id) == ["acme/app", "acme/docs"])
        #expect(model.repositoryCursor == nil)
    }

    @MainActor
    @Test func scopeChangeClearsStateAndExpiredConnectorClearsRepositories() async {
        let repo = CloudGitHubRepository(owner: "acme", name: "app", isPrivate: true, defaultBranch: "main")
        let scope = Scope()
        let fake = FakeConnector(statuses: [
            [CloudConnectorStatus(provider: "github", state: .installed)],
            [CloudConnectorStatus(provider: "github", state: .expired)]
        ], pages: ["": CloudGitHubRepositoryPage(repos: [repo])])
        let model = CloudGitHubConnectorModel(client: fake, openInstallURL: { _ in }, retryRepository: {}, scopeIsCurrent: { scope.current })
        _ = await model.refresh()
        await model.searchRepositories("")
        #expect(model.repositories == [repo])
        _ = await model.refresh()
        #expect(model.state == .expired)
        #expect(model.repositories.isEmpty)
        scope.current = false
        #expect(await model.refresh() == nil)
        #expect(model.state == nil && model.repositories.isEmpty && model.repositoryCursor == nil)
    }

    @Test func jsonClientDecodesC1ContractAndUsesConnectorPaths() async throws {
        let client = CloudGitHubConnectorJSONClient { path, query in
            switch path {
            case "/v1/connectors":
                return Data(#"[{"provider":"github","state":"needs-auth"}]"#.utf8)
            case "/v1/connectors/github/install":
                return Data(#"{"url":"https://github.com/apps/cmux/installations/new"}"#.utf8)
            case "/v1/connectors/github/repos":
                #expect(query["query"] == "acme")
                #expect(query["cursor"] == "next")
                return Data(#"{"repos":[{"owner":"acme","name":"app","private":true,"defaultBranch":"main"}],"cursor":null}"#.utf8)
            default:
                throw CloudGitHubConnectorClientError.requestFailed
            }
        }
        #expect(try await client.connectorStatuses() == [CloudConnectorStatus(provider: "github", state: .needsAuth)])
        #expect((try await client.installURL()).host == "github.com")
        let page = try await client.repositories(query: "acme", cursor: "next")
        #expect(page.repos == [CloudGitHubRepository(owner: "acme", name: "app", isPrivate: true, defaultBranch: "main")])
    }

    @Test func repositoryErrorsStayDistinguishable() {
        #expect(CloudGitHubConnectorClientError.classify(code: "private") == .privateRepository)
        #expect(CloudGitHubConnectorClientError.classify(status: 404) == .notFound)
        #expect(CloudGitHubConnectorClientError.classify(code: "not_configured") == .unavailable)
        #expect(CloudGitHubConnectorClientError.classify(transport: URLError(.notConnectedToInternet)) == .offline)
    }

    @MainActor
    @Test func expiryDiscardsARepositoryPageAlreadyInFlight() async {
        let fake = DelayedConnector()
        let model = CloudGitHubConnectorModel(client: fake, openInstallURL: { _ in }, retryRepository: {})
        let loading = Task { await model.searchRepositories("") }
        for await _ in fake.started { break }
        #expect(await model.refresh() == .expired)
        await fake.finish()
        await loading.value
        #expect(model.repositories.isEmpty && model.repositoryCursor == nil)
        #expect(!model.isLoadingRepositories)
    }

    private actor DelayedConnector: CloudGitHubConnectorClient {
        nonisolated let started: AsyncStream<Void>
        private let signal: AsyncStream<Void>.Continuation
        private var pending: CheckedContinuation<CloudGitHubRepositoryPage, Never>?
        init() {
            let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            started = stream.stream
            signal = stream.continuation
        }
        func connectorStatuses() async throws -> [CloudConnectorStatus] { [.init(provider: "github", state: .expired)] }
        func installURL() async throws -> URL { throw CloudGitHubConnectorClientError.unavailable }
        func repositories(query: String, cursor: String?) async throws -> CloudGitHubRepositoryPage {
            await withCheckedContinuation { pending = $0; signal.yield(()); signal.finish() }
        }
        func finish() {
            pending?.resume(returning: .init(repos: [.init(owner: "octo", name: "paint", isPrivate: true, defaultBranch: "main")], cursor: "next"))
            pending = nil
        }
    }

    @MainActor
    private final class Scope {
        var current = true
    }

    private actor Recorder {
        var opened: [URL] = []
        var retries = 0
        func open(_ url: URL) { opened.append(url) }
        func retry() { retries += 1 }
        func urls() -> [URL] { opened }
    }

    private actor FakeConnector: CloudGitHubConnectorClient {
        var statuses: [[CloudConnectorStatus]]
        var install: URL
        var pages: [String: CloudGitHubRepositoryPage]

        init(statuses: [[CloudConnectorStatus]] = [[]],
             install: URL = URL(string: "https://github.com/apps/cmux/installations/new") ?? URL(fileURLWithPath: "/"),
             pages: [String: CloudGitHubRepositoryPage] = [:]) {
            self.statuses = statuses
            self.install = install
            self.pages = pages
        }

        func connectorStatuses() async throws -> [CloudConnectorStatus] {
            if statuses.count > 1 { return statuses.removeFirst() }
            return statuses.first ?? []
        }

        func installURL() async throws -> URL { install }

        func repositories(query: String, cursor: String?) async throws -> CloudGitHubRepositoryPage {
            pages[cursor ?? ""] ?? CloudGitHubRepositoryPage(repos: [])
        }
    }
}
