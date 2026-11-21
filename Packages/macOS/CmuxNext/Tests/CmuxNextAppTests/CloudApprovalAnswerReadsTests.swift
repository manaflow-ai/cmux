import CmuxNextDaemonService
import Foundation
import Testing

/// A Cloud create's approval is answered in two round trips, not three: the open approve items are
/// read beside `integration.approval.get` (they need nothing of each other), and the answer goes only
/// after the request checked out. A request that does not check out answers nothing.
@Suite(.timeLimit(.minutes(1))) struct CloudApprovalAnswerReadsTests {
    /// The person's session as the API Worker sees it: `integration.approval.get` answers only once
    /// the `feed.list` read is in flight too, so a reads-one-after-the-other answer never ends.
    actor Wire {
        var ops: [String] = []
        var heldOp = "cloud.machine.create"
        private var listed = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func setHeldOp(_ op: String) { heldOp = op }

        func answer(_ body: Data) async throws -> Data {
            let call = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
            let op = call["op"] as? String ?? ""
            ops.append(op)
            let value: [String: Any]
            switch op {
            case "integration.approval.get":
                if !listed { await withCheckedContinuation { waiting.append($0) } }
                value = ["value": ["op": heldOp, "state": "pending", "params": ["name": "dev"], "digest": "dg_1"]]
            case "feed.list":
                listed = true
                waiting.forEach { $0.resume() }
                waiting = []
                value = ["value": ["items": [Self.item]]]
            case "feed.answer":
                value = ["ok": true]
            default:
                value = ["ok": false, "error": ["code": "validation.invalid"]]
            }
            return try JSONSerialization.data(withJSONObject: value)
        }

        private static var item: [String: Any] { [
            "id": "fi_1", "kind": "approve",
            "prompt": ["action": ["type": "tool", "tool": "cloud.machine.create",
                                  "input": ["approval": ["team": "team_a", "request": "apr_1", "digest": "dg_1"]]]],
            "poster": ["kind": "integration", "scope": "system:cloud:team_a"],
        ] }
    }

    private func approve(_ wire: Wire) async throws {
        let approvals = CloudApprovalAnswer(call: { _, body in try await wire.answer(body) })
        try await approvals.approve(request: "apr_1", op: "cloud.machine.create",
                                    params: JSONSerialization.data(withJSONObject: ["name": "dev"]), team: "team_a")
    }

    @Test func theRequestAndTheOpenItemsAreReadTogether() async throws {
        let wire = Wire()
        try await approve(wire)
        let ops = await wire.ops
        #expect(Set(ops.prefix(2)) == ["integration.approval.get", "feed.list"])
        #expect(ops.last == "feed.answer")
        #expect(ops.count == 3, "one round trip more than the two reads and the answer")
    }

    @Test func aRequestForAnotherOpAnswersNothing() async throws {
        let wire = Wire()
        await wire.setHeldOp("cloud.machine.delete")
        await #expect(throws: CloudApprovalAnswer.Failure.mismatch(request: "apr_1", reason: "op")) { try await approve(wire) }
        #expect(await !wire.ops.contains("feed.answer"))
    }
}
