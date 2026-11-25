import CMUXAuthCore
@testable import CmuxNextCloud
import Foundation
import Testing

/// The person's hand-off and fork-run calls are the cmux daemon's `cloud.owner.*` (one `cmux cloud api` request
/// on the child's stdin), not Swift HTTP; a fake child stands in for the bundled cmux.
@Suite struct CloudOwnerDaemonTests {
    nonisolated final class Seen: @unchecked Sendable {
        // @unchecked: `requests` is read and written only under `lock`.
        private let lock = NSLock()
        private var requests: [[String: Any]] = []
        func add(_ r: [String: Any]) { lock.withLock { requests.append(r) } }
        var all: [[String: Any]] { lock.withLock { requests } }
    }

    private func owner(_ seen: Seen, answer: @escaping @Sendable (String) -> String) -> CloudOwnerAPIClient {
        var owner = CloudOwnerAPIClient(baseURL: URL(string: "https://owner.standin.invalid") ?? URL(fileURLWithPath: "/"),
                                        accessToken: { "access" }, teamID: { "team_cmux" }, buildSpace: .nightly)
        owner.daemonCall = { input, _ in
            let request = (try JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
            seen.add(request)
            return Data((answer(request["call"] as? String ?? "") + "\n").utf8)
        }
        return owner
    }

    static let turn = #"{"id":"ho_0123456789abcdef0123","sessionId":"s1","machine":"m1","turn":2,"state":"open","status":"running"}"#

    @Test func handOffCallsAreTheDaemonsOwnerOps() async throws {
        let seen = Seen()
        let owner = owner(seen) { call in
            switch call {
            case "owner.handoffs":
                #"{"ok":true,"body":[{"id":"ho_0123456789abcdef0123","sessionId":"s1","status":"running","createdAt":5}]}"#
            case "owner.handoff_begin_turn":
                #"{"ok":true,"body":{"refusal":"handoff.turn_running","id":"ho_0123456789abcdef0123","sessionId":"s1","machine":"m1","turn":2,"state":"open","status":"running"}}"#
            default:
                #"{"ok":true,"body":\#(Self.turn)}"#
            }
        }
        let list = try await owner.handoffs(pages: 99)
        #expect(list.map(\.id) == ["ho_0123456789abcdef0123"])
        let opened = try await owner.handoffOpen(session: "s1", machine: "m1")
        #expect(opened.turn == 2 && opened.refusal == nil)
        let begun = try await owner.handoffBeginTurn("ho_0123456789abcdef0123", after: -3)
        #expect(begun.refusal == "handoff.turn_running")

        let requests = seen.all
        #expect(requests.map { $0["call"] as? String } == ["owner.handoffs", "owner.handoff_open", "owner.handoff_begin_turn"])
        #expect(requests.allSatisfy { $0["auth"] as? String == "owner" && $0["credential"] as? String == "access" })
        #expect((requests[0]["args"] as? [String: Any])?["pages"] as? Int == 50)
        #expect((requests[1]["args"] as? [String: Any])?["session"] as? String == "s1")
        #expect((requests[2]["args"] as? [String: Any])?["after"] as? Int == 0)
    }

    @Test func aDaemonFailureIsTheSameAPIError() async {
        let owner = owner(Seen()) { _ in #"{"ok":false,"error":{"kind":"http","status":404,"body":"{}"}}"# }
        await #expect(throws: CloudAPIError.self) { try await owner.handoffOpen(session: "s1", machine: "m1") }
        let notTurn = self.owner(Seen()) { _ in #"{"ok":true,"body":{"id":"nope"}}"# }
        await #expect(throws: CloudAPIError.self) { try await notTurn.handoffOpen(session: "s1", machine: "m1") }
    }
}
