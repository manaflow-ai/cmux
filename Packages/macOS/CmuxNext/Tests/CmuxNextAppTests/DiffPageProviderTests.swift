@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// diff-host S4: one diff tab's `cmux.diff.*` namespace over a fake sidecar
/// that speaks the stdio protocol. A tab only ever acts as itself: its token
/// and group on every request, only its own sessions closed, its grant gone
/// when it closes.
@MainActor
@Suite(.serialized)
struct DiffPageProviderTests {
    struct World {
        let root: URL
        let repo: String
        let grant: DiffSessionGrant
        let sidecar: FakeDiffSidecar
        let ready: Task<DiffTabReady, any Error>
        let provider: DiffPageProvider
    }

    static func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-diff-root-\(UUID().uuidString)")
        return try DiffSessionRoot.prepare(url)
    }

    static func repository() throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-diff-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static func world(root: URL? = nil, hold: String? = nil) throws -> World {
        let root = try root ?? Self.root()
        let repo = try repository()
        let grant = try DiffSessionGrant.create(root: root, repository: repo)
        let config = DiffPageConfig.make(repository: DiffRepository(root: repo, branch: "feature", base: "origin/main"), token: grant.token)
        let ready = Task { () async throws -> DiffTabReady in DiffTabReady(grant: grant, config: config) }
        let sidecar = FakeDiffSidecar(root: root, hold: hold)
        return World(root: root, repo: repo, grant: grant, sidecar: sidecar, ready: ready,
                     provider: DiffPageProvider(ready: ready, sidecar: sidecar, languages: nil))
    }

    static let context = PageCallContext(page: "cmux.diff")

    static func call(_ provider: DiffPageProvider, _ op: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await provider.call(op, params: params, context: context)
    }

    static func open(_ world: World, token: String? = nil) async throws -> String {
        let params: JSONValue = ["source": ["kind": "branch", "repoRoot": .string(world.repo), "baseRef": "origin/main"],
                                 "capabilityToken": .string(token ?? world.grant.token)]
        let result = try await call(world.provider, "cmux.diff.sessionOpen", params)
        return try #require(DiffPageProvider.openedSession(result))
    }

    @Test func configIsTheTabsBranchSessionWithNoOptionalOps() async throws {
        let world = try Self.world()
        let config = try await Self.call(world.provider, "cmux.diff.config")
        let payload = try #require(config["payload"])
        #expect(payload["capabilityToken"]?.stringValue == world.grant.token)
        #expect(payload["transport"]?["kind"]?.stringValue == "page")
        #expect(payload["sessionSource"] == ["kind": "branch", "repoRoot": .string(world.repo), "baseRef": "origin/main"])
        #expect(payload["headRef"]?.stringValue == "feature")
        // Comments arrive with S5: the page keeps them hidden.
        #expect(config["ops"] == .array([]))
        await world.provider.close()
    }

    @Test func aRepositoryWithoutABaseStartsOnTheUnstagedChanges() {
        let config = DiffPageConfig.make(repository: DiffRepository(root: "/r", branch: nil, base: nil), token: "t")
        #expect(config["payload"]?["sessionSource"] == ["kind": "unstaged", "repoRoot": "/r"])
        #expect(config["payload"]?["headRef"]?.stringValue == "HEAD")
    }

    /// The page's token, session id and group never reach the sidecar.
    @Test func everyRequestCarriesTheTabsOwnTokenAndGroup() async throws {
        let world = try Self.world()
        let session = try await Self.open(world, token: String(repeating: "a", count: 48))
        _ = try await Self.call(world.provider, "cmux.diff.branchList",
                                ["repoRoot": .string(world.repo), "capabilityToken": "someone-elses-token-0000"])
        _ = try await Self.call(world.provider, "cmux.diff.branchChange",
                                ["groupId": "another-tab", "repoRoot": .string(world.repo), "baseRef": "main", "capabilityToken": "x"])
        let requests = world.sidecar.requests
        #expect(world.sidecar.methods == ["sessionOpen", "branchList", "branchChange"])
        for request in requests {
            #expect((request["params"] as? [String: Any])?["capabilityToken"] as? String == world.grant.token)
        }
        #expect((requests[0]["params"] as? [String: Any])?["sessionId"] as? String == session)
        #expect((requests[2]["params"] as? [String: Any])?["groupId"] as? String == world.grant.group)
        #expect(world.provider.sessions.count == 2)
        await world.provider.close()
    }

    @Test func aTabClosesOnlyItsOwnSessions() async throws {
        let world = try Self.world()
        await #expect(throws: PageError(code: "notAllowed", message: "Diff session is not authorized")) {
            try await Self.call(world.provider, "cmux.diff.sessionClose",
                                ["sessionId": .string(UUID().uuidString.lowercased()), "capabilityToken": .string(world.grant.token)])
        }
        #expect(world.sidecar.methods.isEmpty)
        let session = try await Self.open(world)
        let closed = try await Self.call(world.provider, "cmux.diff.sessionClose", ["sessionId": .string(session)])
        #expect(closed["type"]?.stringValue == "sessionClosed")
        #expect(world.provider.sessions.isEmpty)
        await world.provider.close()
    }

    @Test func closingTheTabClosesItsSessionsAndRemovesItsGrant() async throws {
        let world = try Self.world()
        let session = try await Self.open(world)
        let patch = world.root.appending(path: "diff-session-\(session).patch")
        #expect(FileManager.default.fileExists(atPath: patch.path))
        await world.provider.close()
        #expect(world.sidecar.methods == ["sessionOpen", "sessionClose"])
        #expect(!FileManager.default.fileExists(atPath: patch.path))
        let left = try FileManager.default.contentsOfDirectory(atPath: world.root.path).filter { $0.contains(world.grant.token) || $0.contains(world.grant.group) }
        #expect(left.isEmpty, "\(left)")
        await #expect(throws: PageError.closed) { try await Self.call(world.provider, "cmux.diff.config") }
    }

    /// The page closes its first open before it answered (the pending id):
    /// the child stops, the call answers `sessionClosed`, and the session the
    /// open may have published is closed afterwards.
    @Test func closingThePendingSessionStopsTheOpenInFlight() async throws {
        let world = try Self.world(hold: "sessionOpen")
        let open = Task { try await Self.open(world) }
        #expect(await DiffSidecarProcessTests.becomesTrue { world.sidecar.heldCount == 1 })
        let closed = try await Self.call(world.provider, "cmux.diff.sessionClose", ["sessionId": .string(DiffPageProvider.pendingSessionID)])
        #expect(closed["type"]?.stringValue == "sessionClosed")
        world.sidecar.release()
        await #expect(throws: (any Error).self) { try await open.value }
        #expect(await DiffSidecarProcessTests.becomesTrue { world.sidecar.methods == ["sessionOpen", "sessionClose"] })
        await world.provider.close()
    }

    @Test func onlyTheSidecarMethodsAndHostOpsAreServed() async throws {
        let world = try Self.world()
        for op in ["cmux.diff.comments", "cmux.diff.rm", "cmux.diff.", "cmux.git.status"] {
            await #expect(throws: PageError.unknownOp(op)) { try await Self.call(world.provider, op) }
        }
        let handshake = try await Self.call(world.provider, "cmux.diff.protocolHandshake")
        #expect(handshake["type"]?.stringValue == "handshake")
        #expect(world.sidecar.requests.first?["params"] == nil)
        await world.provider.close()
    }

    @Test func aFolderWithoutARepositoryShowsItsMessage() async throws {
        let ready = Task { () async throws -> DiffTabReady in throw DiffTabFailure(title: "notes", message: "no repo") }
        let provider = DiffPageProvider(ready: ready, sidecar: nil, languages: nil)
        let config = try await Self.call(provider, "cmux.diff.config")
        #expect(config["payload"]?["statusMessage"]?.stringValue == "no repo")
        #expect(config["payload"]?["statusIsError"] == .bool(true))
        await #expect(throws: PageError(code: "sidecarUnavailable", message: "no repo")) {
            try await Self.call(provider, "cmux.diff.sessionOpen", ["source": ["kind": "unstaged", "repoRoot": "/r"]])
        }
    }

    @Test func eventStreamSubscribesAndCancels() async throws {
        let world = try Self.world()
        let subscription = try await world.provider.subscribe("cmux.diff.events", filter: .object([:]), context: Self.context) { _ in }
        #expect(world.provider.eventSubscriberCount == 1)
        subscription.cancel()
        #expect(world.provider.eventSubscriberCount == 0)
        await #expect(throws: PageError.unknownOp("cmux.diff.languages")) {
            _ = try await world.provider.subscribe("cmux.diff.languages", filter: .object([:]), context: Self.context) { _ in }
        }
        await world.provider.close()
    }
}
