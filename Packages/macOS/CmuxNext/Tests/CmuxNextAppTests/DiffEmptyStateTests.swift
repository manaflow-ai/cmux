@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// diff-host S4, "Empty state": a diff tab with no repository answers
/// `{pick: true}`; `cmux.diff.recents`, `cmux.diff.chooseFolder` and
/// `cmux.diff.open` give it one, and every open is a recent.
@MainActor
@Suite(.serialized)
struct DiffEmptyStateTests {
    /// The tab's owner: one repository (`repo`), a fixed chooser answer.
    final class FakeHost: DiffTabHosting {
        let root: URL
        let repo: String
        var chosen: URL?
        var opened: [(String, DiffOpenSource)] = []
        var chooserStart: URL?

        init(root: URL, repo: String) {
            self.root = root
            self.repo = repo
        }

        func repository(at folder: URL) async -> DiffRepository? {
            folder.path.hasPrefix(repo) ? DiffRepository(root: repo, branch: "feature", base: "origin/main") : nil
        }

        func prepare(_ repository: DiffRepository, source: DiffOpenSource) -> Task<DiffTabReady, any Error> {
            let root = root
            return Task {
                let grant = try DiffSessionGrant.create(root: root, repository: repository.root)
                return DiffTabReady(grant: grant, config: DiffPageConfig.make(repository: repository, source: source, token: grant.token))
            }
        }

        func recents() async -> JSONValue { ["home": "/Users/me", "items": [["path": .string(repo), "openedAt": 1]]] }

        func chooseFolder(start: URL?) async -> URL? {
            chooserStart = start
            return chosen
        }

        func opened(_ repository: DiffRepository, source: DiffOpenSource) { opened.append((repository.root, source)) }
    }

    static func world() throws -> (DiffPageProvider, FakeHost, FakeDiffSidecar) {
        let root = try DiffPageProviderTests.root()
        let host = FakeHost(root: root, repo: try DiffPageProviderTests.repository())
        let sidecar = FakeDiffSidecar(root: root)
        return (DiffPageProvider(ready: nil, sidecar: sidecar, languages: nil, host: host), host, sidecar)
    }

    static func call(_ provider: DiffPageProvider, _ op: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await DiffPageProviderTests.call(provider, op, params)
    }

    @Test func aTabWithoutARepositoryAsksToPick() async throws {
        let (provider, _, sidecar) = try Self.world()
        #expect(provider.isPicking)
        #expect(try await Self.call(provider, "cmux.diff.config") == ["pick": true])
        await #expect(throws: PageError(code: "sidecarUnavailable", message: "No repository is open")) {
            try await Self.call(provider, "cmux.diff.branchList", ["repoRoot": "/r"])
        }
        #expect(sidecar.methods.isEmpty)
        await provider.close()
    }

    @Test func recentsAndChooseFolderComeFromTheHost() async throws {
        let (provider, host, _) = try Self.world()
        let recents = try await Self.call(provider, "cmux.diff.recents")
        #expect(recents["items"]?.arrayValue?.first?["path"]?.stringValue == host.repo)
        #expect(try await Self.call(provider, "cmux.diff.chooseFolder", ["start": "/tmp"]) == .null)
        #expect(host.chooserStart?.path == "/tmp")
        host.chosen = URL(fileURLWithPath: host.repo, isDirectory: true)
        #expect(try await Self.call(provider, "cmux.diff.chooseFolder") == ["path": .string(host.repo)])
        await provider.close()
    }

    @Test func openingAFolderInNoRepositoryIsRefused() async throws {
        let (provider, host, _) = try Self.world()
        await #expect(throws: PageError(code: "cmux.diff.not_a_repo", message: "/tmp/elsewhere")) {
            try await Self.call(provider, "cmux.diff.open", ["path": "/tmp/elsewhere", "source": ["kind": "branch"]])
        }
        #expect(provider.isPicking)
        #expect(host.opened.isEmpty)
        await #expect(throws: PageError.invalidParams("path is required")) {
            try await Self.call(provider, "cmux.diff.open", ["path": "relative"])
        }
    }

    /// The answer is the config the page renders in place; the tab is
    /// recorded as opened; a second repository retires the first grant.
    @Test func openingAFolderGivesTheTabItsRepository() async throws {
        let (provider, host, _) = try Self.world()
        let config = try await Self.call(provider, "cmux.diff.open",
                                         ["path": .string(host.repo + "/sub"), "source": ["kind": "branch", "baseRef": "HEAD"]])
        #expect(config["payload"]?["sessionSource"] == ["kind": "branch", "repoRoot": .string(host.repo), "baseRef": "HEAD"])
        #expect(!provider.isPicking)
        #expect(host.opened.count == 1 && host.opened[0].0 == host.repo && host.opened[0].1 == .branch(base: "HEAD"))
        #expect(try await Self.call(provider, "cmux.diff.config") == config)
        let first = try #require(try await provider.ready?.value.grant)
        _ = try await Self.call(provider, "cmux.diff.open", ["path": .string(host.repo), "source": ["kind": "staged"]])
        #expect(!FileManager.default.fileExists(atPath: first.manifestURL.path))
        let second = try #require(try await provider.ready?.value.grant)
        #expect(second.token != first.token)
        #expect(host.opened.last?.1 == .staged)
        await provider.close()
        #expect(!FileManager.default.fileExists(atPath: second.manifestURL.path))
    }

    @Test func thePagesSourceMapsToTheOpenSource() {
        #expect(DiffOpenSource(page: ["kind": "branch"]) == .default)
        #expect(DiffOpenSource(page: ["kind": "branch", "baseRef": "main"]) == .branch(base: "main"))
        #expect(DiffOpenSource(page: ["kind": "staged", "repoRoot": "/r"]) == .staged)
        #expect(DiffOpenSource(page: ["kind": "unstaged"]) == .unstaged)
        #expect(DiffOpenSource(page: nil) == .default)
        #expect(DiffRecent.sourceKind(.branch(base: "HEAD")) == "uncommitted")
        #expect(DiffRecent.sourceKind(.default) == "branch")
    }

    @Test func recentsAreNewestFirstUniqueAndKept() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-diff-recents-\(UUID().uuidString)/diff-recents.json")
        let recents = DiffRecents(url: url)
        let a = DiffRepository(root: "/r/a", branch: "main", base: nil), b = DiffRepository(root: "/r/b", branch: nil, base: nil)
        await recents.record(a, source: .default, at: Date(timeIntervalSince1970: 1))
        await recents.record(b, source: .staged, at: Date(timeIntervalSince1970: 2))
        await recents.record(a, source: .unstaged, at: Date(timeIntervalSince1970: 3))
        #expect(await recents.list().map(\.path) == ["/r/a", "/r/b"])
        #expect(await recents.list().first == DiffRecent(path: "/r/a", name: "a", openedAt: 3000, source: "unstaged", branch: "main"))
        await recents.flush()
        let reread = DiffRecents(url: url)
        #expect(await reread.list().map(\.path) == ["/r/a", "/r/b"])
        let page = await reread.page()
        #expect(page["home"]?.stringValue == NSHomeDirectory())
        #expect(page["items"]?.arrayValue?.last?["source"]?.stringValue == "staged")
        for index in 0..<(DiffRecents.limit + 5) {
            await recents.record(DiffRepository(root: "/r/\(index)", branch: nil, base: nil), source: .default)
        }
        #expect(await recents.list().count == DiffRecents.limit)
    }
}
