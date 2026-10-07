import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The app host's copy of the cmux model catalog (decision M2): fetched from the cmux server with
/// If-None-Match, kept on disk for the next launch, served offline, never replaced by a bad body.
@Suite struct AgentModelCatalogStoreTests {
    fileprivate nonisolated static let endpoint = URL(string: "https://cmux.test/api/models/catalog")!
    private static let body = Data(#"{"schemaVersion":1,"generatedAt":"2026-10-06T18:00:00.000Z","source":"live","harnesses":[{"id":"claude","name":"Claude Code","brand":"claude","families":["claude"],"modelSource":"catalog","models":[]}],"models":{},"providers":{}}"#.utf8)

    /// A scripted server: each request takes the next answer and is recorded.
    private actor Server {
        private var answers: [Result<(Int, Data, String?), Error>]
        private var requests: [URLRequest] = []
        init(_ answers: [Result<(Int, Data, String?), Error>]) { self.answers = answers }
        func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            let answer = answers.isEmpty ? .failure(URLError(.notConnectedToInternet)) : answers.removeFirst()
            let (status, data, etag) = try answer.get()
            var headers = ["Content-Type": "application/json"]
            if let etag { headers["ETag"] = etag }
            let url = request.url ?? AgentModelCatalogStoreTests.endpoint
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers) ?? HTTPURLResponse()
            return (data, response)
        }
        var count: Int { requests.count }
        func header(_ index: Int, _ name: String) -> String? { requests[index].value(forHTTPHeaderField: name) }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "model-catalog-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(_ server: Server, cache: URL, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> AgentModelCatalogStore {
        AgentModelCatalogStore(endpoint: Self.endpoint, cacheFile: cache.appending(path: "model-catalog.json"),
                               fetch: { try await server.fetch($0) }, now: { now })
    }

    @Test func aFetchedCatalogIsServedAndKeptOnDiskForTheNextLaunch() async throws {
        let cache = try directory()
        let server = Server([.success((200, Self.body, "\"v1\""))])
        let first = await store(server, cache: cache).current(refresh: false, remote: true)
        #expect(first.delivery == "network")
        #expect(first.catalog?["schemaVersion"] == .number(1))
        #expect(first.changed)

        // The next launch answers from disk at once and revalidates with the saved ETag.
        let offline = Server([.success((304, Data(), "\"v1\""))])
        let next = store(offline, cache: cache)
        let second = await next.current(refresh: false, remote: true)
        #expect(second.catalog?["harnesses"]?.arrayValue?.count == 1)
        #expect(second.delivery == "disk")
        #expect(await offline.count == 1)
        #expect(await offline.header(0, "If-None-Match") == "\"v1\"")
        #expect(!second.changed)
    }

    @Test func offlineWithACopyServesTheDiskCopyAndOfflineWithoutOneServesNothing() async throws {
        let cache = try directory()
        _ = await store(Server([.success((200, Self.body, nil))]), cache: cache).current(refresh: false, remote: true)
        let down = await store(Server([.failure(URLError(.notConnectedToInternet))]), cache: cache).current(refresh: false, remote: true)
        #expect(down.delivery == "disk")
        #expect(down.catalog != nil)

        let empty = await store(Server([.failure(URLError(.timedOut))]), cache: try directory()).current(refresh: false, remote: true)
        #expect(empty.catalog == nil)
        #expect(empty.delivery == nil)
    }

    @Test func aBadBodyNeverReplacesTheGoodCopy() async throws {
        let cache = try directory()
        let server = Server([
            .success((200, Self.body, "\"v1\"")),
            .success((200, Data(#"{"schemaVersion":2}"#.utf8), "\"v2\"")),
            .success((500, Data("oops".utf8), nil)),
        ])
        let catalog = store(server, cache: cache)
        _ = await catalog.current(refresh: false, remote: true)
        let afterBad = await catalog.current(refresh: true, remote: true)
        #expect(afterBad.catalog?["schemaVersion"] == .number(1))
        let afterError = await catalog.current(refresh: true, remote: true)
        #expect(afterError.catalog?["schemaVersion"] == .number(1))
        let reloaded = await store(Server([]), cache: cache).current(refresh: false, remote: false)
        #expect(reloaded.catalog?["schemaVersion"] == .number(1))
    }

    @Test func aFreshCopyIsNotFetchedAgainUntilItIsOldOrARefreshAsks() async throws {
        let cache = try directory()
        let server = Server([.success((200, Self.body, "\"v1\"")), .success((304, Data(), "\"v1\"")), .success((304, Data(), "\"v1\""))])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let catalog = store(server, cache: cache, now: start)
        _ = await catalog.current(refresh: false, remote: true)
        _ = await catalog.current(refresh: false, remote: true)
        #expect(await server.count == 1)
        _ = await catalog.current(refresh: true, remote: true)
        #expect(await server.count == 2)
        let later = start.addingTimeInterval(7 * 3600)
        await catalog.setClockForTests { later }
        _ = await catalog.current(refresh: false, remote: true)
        #expect(await server.count == 3)
    }

    @Test func remoteOffNeverFetches() async throws {
        let server = Server([.success((200, Self.body, nil))])
        let result = await store(server, cache: try directory()).current(refresh: true, remote: false)
        #expect(await server.count == 0)
        #expect(result.catalog == nil)
    }

    @Test func thePageAsksForTheCatalogByMethodName() {
        #expect(AgentPaneRequest(body: ["method": "models.catalog", "params": [:]] as [String: Any]) == .modelCatalog(refresh: false))
        #expect(AgentPaneRequest(body: ["method": "models.catalog", "params": ["refresh": true]] as [String: Any]) == .modelCatalog(refresh: true))
        #expect(AgentPageOps.all.contains("cmux.agent.models.catalog"))
    }

    @Test func theHostReplyCarriesCatalogDeliveryAndTheUserLayer() {
        let user: JSONValue = ["remoteCatalog": .bool(false)]
        let reply = AgentModelCatalogStore.reply(catalog: nil, delivery: nil, user: user)
        #expect(reply == ["catalog": .null, "delivery": .null, "user": user])
        #expect(AgentModelCatalogStore.remoteEnabled(user) == false)
        #expect(AgentModelCatalogStore.remoteEnabled(nil))
        #expect(AgentPageEvent.modelCatalog(reply).kind == "models.catalog")
    }
}
