@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextDaemonService
@testable import CmuxNextFeed
import Foundation
import Testing

/// cmux#32354: the person answers a Cloud create's approval hold on the phone before this Mac answers
/// it. The approved op still runs, so `integration.approval.get` reads pending, while its feed item is
/// closed: answering it finds no open item. The create must go on with the op's answer and never
/// answer the hold again. The same "feed item or team" reply also means the item belongs to another
/// team: that create must still fail at once. The Mac hears the phone's answer from the feed owner's
/// push of the closed item (``CloudApprovalHolds``), so it does not ask the server again.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CloudApprovalHoldRaceTests {
    /// The Cloud backend and the person's feed, as the Mac's session sees them.
    @MainActor final class Backend {
        /// The team whose Cloud owner posted the hold's feed item.
        var itemTeam = "team_a"
        /// The person answered the hold on the phone: its feed item is closed.
        var answeredOnPhone = false
        var sameKeyCallsAfterAnswer = 0
        var feedAnswers = 0
        var sessionCalls = 0
        var held: Any = [String: Any]()

        /// One `cloud.machine.create` with the flow's key.
        func run(_ args: JSONValue) throws -> JSONValue {
            held = try JSONSerialization.jsonObject(with: JSONEncoder().encode(args))
            let pending = CloudAppOpFailure(code: CloudAppOpFailure.approvalPending, message: "", details: .object(["request": .string("apr_1")]))
            guard answeredOnPhone else { throw pending }
            sameKeyCallsAfterAnswer += 1
            // The approved op runs in the backend: the first same-key call after the answer still reads pending.
            if sameKeyCallsAfterAnswer == 1 { throw pending }
            return .object(["machine": .object(["id": .string("vm_1")])])
        }

        /// One API Worker call as the person's session (`v1/read`, `v1/ops`).
        func session(_ body: Data) throws -> Data {
            sessionCalls += 1
            let call = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
            let params = call["params"] as? [String: Any] ?? [:]
            let value: [String: Any]
            switch call["op"] as? String {
            case "integration.approval.get":
                // A running approved op reads pending.
                value = ["value": ["op": "cloud.machine.create", "state": "pending", "params": held, "digest": "dg_1"]]
            case "feed.list":
                let wantsOpen = params["state"] as? String == "open"
                value = ["value": ["items": answeredOnPhone == !wantsOpen ? [item] : []]]
            case "feed.answer":
                feedAnswers += 1
                value = ["ok": true]
            default:
                value = ["ok": false, "error": ["code": "validation.invalid"]]
            }
            return try JSONSerialization.data(withJSONObject: value)
        }

        private var item: [String: Any] {
            ["id": "fi_1", "kind": "approve",
             "prompt": ["action": ["type": "tool", "tool": "cloud.machine.create",
                                   "input": ["approval": ["team": itemTeam, "request": "apr_1", "digest": "dg_1"]]]],
             "poster": ["kind": "integration", "scope": "system:cloud:\(itemTeam)"]]
        }
    }

    /// The production flow's shape: the real `CloudApprovalAnswer` for team_a over `backend`, told what the feed shows answered.
    private func flow(_ backend: Backend, holds: CloudApprovalHolds? = nil) -> CloudMachineCreateFlow {
        let approvals = CloudApprovalAnswer(call: { _, body in try await MainActor.run { try backend.session(body) } },
                                            answered: { request, team in await holds?.isAnswered(request, team: team) ?? false })
        return CloudMachineCreateFlow(
            run: { _, args, _, _ in try await MainActor.run { try backend.run(args) } },
            confirm: { _ in true },
            approve: { request, op, params in
                try await approvals.approve(request: request, op: op, params: try JSONEncoder().encode(params), team: "team_a")
            },
            pause: { _ in })
    }

    @Test func aHoldAnsweredOnThePhoneFirstGoesOnWithTheOpsAnswer() async throws {
        let backend = Backend()
        backend.answeredOnPhone = true
        var recorded: [String] = []
        let made = try await flow(backend).create(name: "cloud-chats", startedByPerson: true, onApproved: { recorded.append($0) })
        #expect(made["id"]?.stringValue == "vm_1")
        #expect(backend.feedAnswers == 0, "a hold answered on the phone was answered again")
        #expect(recorded.isEmpty, "nothing was answered here, so nothing is recorded as answered")
    }

    @Test(arguments: [false, true])
    func aHoldOfAnotherTeamFailsAtOnce(answeredOnPhone: Bool) async throws {
        let backend = Backend()
        backend.itemTeam = "team_b"
        backend.answeredOnPhone = answeredOnPhone
        await #expect(throws: CloudApprovalAnswer.Failure.mismatch(request: "apr_1", reason: CloudApprovalAnswer.closedItem)) {
            try await flow(backend).create(name: "cloud-chats", startedByPerson: true)
        }
        #expect(backend.feedAnswers == 0)
    }

    @Test func anotherTeamsHoldTheFeedShowsAnsweredStillFailsAtOnce() async throws {
        let backend = Backend()
        backend.itemTeam = "team_b"
        backend.answeredOnPhone = true
        let holds = CloudApprovalHolds()
        // The person answered team_b's hold on the phone; this create is team_a's.
        holds.recordAnswered([(request: "apr_1", team: "team_b")])
        await #expect(throws: CloudApprovalAnswer.Failure.mismatch(request: "apr_1", reason: CloudApprovalAnswer.closedItem)) {
            try await flow(backend, holds: holds).create(name: "cloud-chats", startedByPerson: true)
        }
        #expect(backend.sessionCalls > 0, "another team's closed hold skipped the create's own team check")
        #expect(backend.feedAnswers == 0)
    }

    @Test func aHoldTheFeedShowsAnsweredIsNotAskedAboutAgain() async throws {
        let backend = Backend()
        let holds = CloudApprovalHolds()
        backend.answeredOnPhone = true
        // The feed owner pushed the closed approve item before the create's first call came back.
        holds.recordAnswered([(request: "apr_1", team: "team_a")])
        let made = try await flow(backend, holds: holds).create(name: "cloud-chats", startedByPerson: true)
        #expect(made["id"]?.stringValue == "vm_1")
        #expect(backend.sessionCalls == 0, "a hold the feed showed answered was looked up or answered again")
    }

    @Test func theFeedKeepsTheCloudHoldOfItsOwnTeamsItemOnly() {
        func hold(scope: String, team: String, poster: String = "integration", home: String = "cloud") -> String? {
            FeedWireDecode.item([
                "id": "fi_1", "title": "Approve a Cloud change from your device", "created_at": 1, "kind": "approve", "state": "answered", "home": home,
                "poster": ["kind": poster, "scope": scope],
                "prompt": ["action": ["type": "tool", "tool": "cloud.machine.create",
                                      "input": ["approval": ["team": team, "request": "apr_1", "digest": "dg_1"]]]],
            ])?.cloudHold?.request
        }
        #expect(hold(scope: "system:cloud:team_a", team: "team_a") == "apr_1")
        #expect(hold(scope: "system:cloud:team_b", team: "team_a") == nil, "another team's owner posted it")
        #expect(hold(scope: "system:connections:team_a", team: "team_a") == nil, "an integrations hold, not a Cloud one")
        #expect(hold(scope: "system:cloud:team_a", team: "team_a", poster: "agent") == nil)
        #expect(hold(scope: "system:cloud:team_a", team: "team_a", home: "local:ins_1") == nil, "a local owner's item")
    }
}
