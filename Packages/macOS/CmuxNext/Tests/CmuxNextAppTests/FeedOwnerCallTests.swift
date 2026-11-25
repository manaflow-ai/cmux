import CmuxNextCloud
import CmuxNextFeedClient
import Foundation
import Testing

/// The feed's `v1/ops` and `v1/read` calls are the cmux daemon's `cloud.owner.op` (one `cmux cloud api` request on
/// the child's stdin), not Swift HTTP; a fake child stands in for the bundled cmux.
@Suite struct FeedOwnerCallTests {
    nonisolated final class Seen: @unchecked Sendable {
        // @unchecked: `requests` is read and written only under `lock`.
        private let lock = NSLock()
        private var requests: [[String: Any]] = []
        func add(_ r: [String: Any]) { lock.withLock { requests.append(r) } }
        var all: [[String: Any]] { lock.withLock { requests } }
    }

    private func call(_ seen: Seen, credential: @escaping FeedOwnerCall.Credential = { "install-token" },
                      team: String? = nil, answer: String) -> FeedOwnerCall {
        FeedOwnerCall(baseURL: URL(string: "https://owner.standin.invalid") ?? URL(fileURLWithPath: "/"),
                      credential: credential, team: team, configuration: .unavailable, machineIO: nil,
                      clientVersion: "1.2.3") { input, _ in
            seen.add((try JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:])
            return Data((answer + "\n").utf8)
        }
    }

    @Test func anOpIsTheDaemonsOwnerOpWithItsBodyAsSent() async throws {
        let seen = Seen()
        let owner = call(seen, team: "team_cmux", answer: #"{"ok":true,"body":{"status":200,"reply":{"ok":true,"value":{"n":1}}}}"#)
        let reply = try await owner.send(.ops, ["op": "feed.list", "params": ["limit": 5, "all": true]])
        #expect(reply.status == 200)
        let body = try FeedOwnerCall.read(reply)
        #expect(body["ok"] as? Bool == true)

        let request = try #require(seen.all.first)
        #expect(request["call"] as? String == "owner.op")
        #expect(request["auth"] as? String == "owner" && request["credential"] as? String == "install-token")
        #expect(request["team"] as? String == "team_cmux")
        let args = try #require(request["args"] as? [String: Any])
        #expect(args["route"] as? String == "ops")
        #expect(args["client_version"] as? String == "1.2.3")
        let text = try #require(args["body_json"] as? String)
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(sent["op"] as? String == "feed.list")
        #expect((sent["params"] as? [String: Any])?["limit"] as? Int == 5)
    }

    @Test func theFeedsPathsAreTheTwoRoutes() {
        #expect(FeedOwnerCall.Route(path: "v1/ops") == .ops)
        #expect(FeedOwnerCall.Route(path: "/v1/read") == .read)
        #expect(FeedOwnerCall.Route(path: "v1/machines") == nil)
    }

    @Test func aRefusalIsTheOwnersErrorAndASpentTokenKeepsItsStatus() async throws {
        let refused = call(Seen(), answer: #"{"ok":true,"body":{"status":403,"reply":{"error":{"code":"feed.forbidden","message":"no"}}}}"#)
        let reply = try await refused.send(.read, ["op": "feed.get"])
        #expect(reply.status == 403)
        #expect(throws: FeedServiceError.self) { try FeedOwnerCall.read(reply) }
        do {
            _ = try FeedOwnerCall.read(reply)
        } catch FeedServiceError.owner(let code, let message) {
            #expect(code == "feed.forbidden" && message == "no")
        }

        let spent = call(Seen(), answer: #"{"ok":true,"body":{"status":401,"reply":null}}"#)
        let unauthorized = try await spent.send(.ops, ["op": "feed.adopt"])
        #expect(unauthorized.status == 401 && unauthorized.body == nil)
        #expect(throws: FeedServiceError.self) { try FeedOwnerCall.read(unauthorized) }
    }

    @Test func noCredentialIsSignedOutAndNothingRuns() async {
        let seen = Seen()
        struct NoToken: Error {}
        let owner = call(seen, credential: { throw NoToken() }, answer: #"{"ok":true,"body":{"status":200,"reply":{}}}"#)
        await #expect(throws: FeedServiceError.self) { try await owner.send(.ops, ["op": "feed.list"]) }
        #expect(seen.all.isEmpty)
    }
}
