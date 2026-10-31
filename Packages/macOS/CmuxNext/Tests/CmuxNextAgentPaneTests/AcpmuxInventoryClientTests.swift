import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxInventoryClientTests {
    @Test func inventoryWaitsForTheSameConnectionsFeatureHandshake() async throws {
        let hello = Self.line(["id": 1, "result": ["_meta": ["acpmux": ["features": ["harnessInventory"]]]]])
        let result = Self.line(["id": 2, "result": ["view": "inventory", "cached": true, "harnesses": []]])
        let split = hello.count / 2
        let stream = Stream(chunks: [
            (1, Self.line(["method": "notice"]) + hello.prefix(split)),
            (1, Data(hello.dropFirst(split))),
            (2, result),
        ])
        let reply = try await AcpmuxStatusClient.exchange("_acpmux/harness/health", params: ["view": "inventory"],
                                                          transport: stream, requiredFeature: "harnessInventory")
        let inventory = try JSONDecoder().decode(AcpmuxHarnessInventory.self, from: JSONSerialization.data(withJSONObject: reply))
        #expect(inventory.harnesses.isEmpty)
        let sent = try Self.requests(await stream.writes())
        #expect(sent.map { $0["method"] as? String } == ["initialize", "_acpmux/harness/health"])
        #expect(sent.last?["params"] as? [String: String] == ["view": "inventory"])
    }

    @Test func censusFilterWaitsForTheSameConnectionsCapability() async throws {
        let capability = "session-list-filters-v1"
        let hello = Self.line(["id": 1, "result": ["_meta": ["acpmux": ["capabilities": [capability]]]]])
        let reply = Self.line(["id": 2, "result": ["sessions": [], "nextCursor": NSNull()]])
        let stream = Stream(chunks: [(1, hello), (2, reply)])
        _ = try await AcpmuxStatusClient.exchange("_acpmux/sessions",
            params: ["localOnly": true, "excludeStatus": ["closed"], "limit": 64],
            transport: stream, requiredCapability: capability)
        let requests = try Self.requests(await stream.writes())
        #expect(requests.map { $0["method"] as? String } == ["initialize", "_acpmux/sessions"])
        let params = try #require(requests.last?["params"] as? [String: Any])
        #expect(params["localOnly"] as? Bool == true)
        #expect(params["excludeStatus"] as? [String] == ["closed"])
    }

    @Test func unsupportedCensusFiltersNeverSendAnUnscopedList() async throws {
        let stream = Stream(chunks: [(1, Self.line(["id": 1, "result": [:]]))])
        do {
            _ = try await AcpmuxStatusClient.exchange("_acpmux/sessions", params: ["localOnly": true],
                transport: stream, requiredCapability: "session-list-filters-v1")
            Issue.record("an unfiltered legacy list was accepted")
        } catch AcpmuxStatusClient.Failure.unsupportedFeature(let feature) {
            #expect(feature == "session-list-filters-v1")
        }
        #expect(try Self.requests(await stream.writes()).map { $0["method"] as? String } == ["initialize"])
    }

    @Test func anOldOrMalformedHandshakeNeverSendsAHealthRequest() async throws {
        for meta: [String: Any] in [[:], ["features": []], ["features": "harnessInventory"], ["features": ["harnessInventoryExtra"]]] {
            // Even a premature operation reply must not bypass negotiation.
            let premature = Self.line(["id": 2, "result": ["view": "inventory", "cached": true, "harnesses": []]])
            let stream = Stream(chunks: [(1, premature + Self.line(["id": 1, "result": ["_meta": ["acpmux": meta]]]))])
            do {
                _ = try await AcpmuxStatusClient.exchange("_acpmux/harness/health", params: ["view": "inventory"],
                                                           transport: stream, requiredFeature: "harnessInventory")
                Issue.record("an unsupported daemon was accepted")
            } catch AcpmuxStatusClient.Failure.unsupportedFeature(let feature) {
                #expect(feature == "harnessInventory")
            }
            #expect(try Self.requests(await stream.writes()).map { $0["method"] as? String } == ["initialize"])
        }
    }

    @Test func aFailedInitializeNeverSendsAHealthRequest() async throws {
        let stream = Stream(chunks: [(1, Self.line(["id": 1, "error": ["code": -32601, "message": "not supported"]]))])
        do {
            _ = try await AcpmuxStatusClient.exchange("_acpmux/harness/health", params: ["view": "inventory"],
                                                       transport: stream, requiredFeature: "harnessInventory")
            Issue.record("a failed initialize was accepted")
        } catch let error as AcpmuxRPCError {
            #expect(error.code == -32601)
        }
        #expect(try Self.requests(await stream.writes()).map { $0["method"] as? String } == ["initialize"])
    }

    @Test func existingCallsKeepTheirPipelinedBehavior() async throws {
        let stream = Stream(chunks: [(1, Self.line(["id": 2, "result": ["ready": true]]))])
        let result = try await AcpmuxStatusClient.exchange("_acpmux/status", params: [:], transport: stream)
        #expect(result["ready"] as? Bool == true)
        #expect(try Self.requests(await stream.writes()).map { $0["method"] as? String } == ["initialize", "_acpmux/status"])
    }

    @Test func aCompleteOversizedFrameIsRejected() async throws {
        let stream = Stream(chunks: [(1, Self.line(["id": 2, "result": ["data": String(repeating: "x", count: 128)]]))])
        do {
            _ = try await AcpmuxStatusClient.exchange("_acpmux/status", params: [:], transport: stream, limit: 64)
            Issue.record("an oversized frame was accepted")
        } catch AcpmuxStatusClient.Failure.rpc(let message) {
            #expect(message == "_acpmux/status reply too large")
        }
    }

    @Test func decodingRefusesLegacyOrNoncachedHealthResults() throws {
        for reply: [String: Any] in [["harnesses": []], ["view": "inventory", "cached": false, "harnesses": []]] {
            let data = try JSONSerialization.data(withJSONObject: reply)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(AcpmuxHarnessInventory.self, from: data) }
        }
    }

    @Test func decodingPreservesUnknownInstallationAndSignInEvidence() throws {
        let reply: [String: Any] = ["view": "inventory", "cached": true, "harnesses": [[
            "id": "custom-profile", "channel": "launcher", "version": NSNull(), "latest": NSNull(),
            "latestCheckedAt": NSNull(), "outdated": false, "auth": "unknown", "checkedAt": 1235,
        ]]]
        let inventory = try JSONDecoder().decode(AcpmuxHarnessInventory.self, from: JSONSerialization.data(withJSONObject: reply))
        let harness = try #require(inventory.harnesses.first)
        #expect(harness.channel == .launcher)
        #expect(harness.auth == .unknown)
        #expect(harness.version == nil)
        #expect(harness.latest == nil)
    }

    private static func requests(_ payloads: [Data]) throws -> [[String: Any]] {
        try payloads.flatMap { payload in
            try payload.split(separator: 0x0A).map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] ?? [:] }
        }
    }

    private static func line(_ object: [String: Any]) -> Data {
        // Fixtures contain only Foundation JSON values.
        (try? JSONSerialization.data(withJSONObject: object)).map { $0 + Data([0x0A]) } ?? Data()
    }

    private actor Stream: AcpmuxRPCTransport {
        private var chunks: [(writes: Int, data: Data)]
        private var sent: [Data] = []
        init(chunks: [(Int, Data)]) { self.chunks = chunks }
        func start() async throws {}
        func send(_ data: Data) async throws { sent.append(data) }
        func receive() async throws -> Data? {
            guard !chunks.isEmpty else { return nil }
            let next = chunks.removeFirst()
            #expect(sent.count == next.writes, "operation was sent before the feature handshake")
            return next.data
        }
        func writes() -> [Data] { sent }
    }
}
