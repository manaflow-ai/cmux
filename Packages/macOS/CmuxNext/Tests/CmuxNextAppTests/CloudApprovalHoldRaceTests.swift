@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// cmux#32354: the person answers a Cloud create's approval hold on the phone, then clicks yes in
/// the Mac's "Create a Cloud machine?" sheet before the Mac's next watch check. The approved op still
/// runs, so `integration.approval.get` reads pending, while its feed item is closed: answering it
/// finds no open item. The create must go on with the op's answer (it was answered), and never
/// answer the hold again. A hold whose item belongs to another team still fails: that is the real
/// mismatch the same "feed item or team" reply also means.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CloudApprovalHoldRaceTests {
    /// The Cloud backend and the person's feed, as the Mac's session sees them.
    @MainActor final class Backend {
        /// The team whose Cloud owner posted the hold's feed item.
        var itemTeam = "team_a"
        /// The person answered the hold on the phone: its feed item is closed.
        var answeredOnPhone = false
        var sameKeyCallsAfterAnswer = 0
        var feedAnswers = 0
        var held: Any = [String: Any]()
        var sheetAnswer: CheckedContinuation<Bool, Never>?
        var sheetCancelled = false
        /// The Mac's watch checks that have not come yet.
        var watchChecks: [AsyncStream<Void>.Continuation] = []

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

        /// The Mac's next watch check, which never comes in these tests; it ends only when cancelled.
        func nextWatchCheck() async throws {
            for await _ in AsyncStream<Void>({ watchChecks.append($0) }) {}
            throw CancellationError()
        }

        func clickInSheet(_ yes: Bool) {
            sheetAnswer?.resume(returning: yes)
            sheetAnswer = nil
        }
    }

    /// The production flow's shape: the real `CloudApprovalAnswer` for team_a over `backend`.
    private func flow(_ backend: Backend) -> CloudMachineCreateFlow {
        let approvals = CloudApprovalAnswer(call: { _, body in try await MainActor.run { try backend.session(body) } })
        return CloudMachineCreateFlow(
            run: { _, args, _, _ in try await MainActor.run { try backend.run(args) } },
            confirm: { _ in
                await withTaskCancellationHandler {
                    await withCheckedContinuation { backend.sheetAnswer = $0 }
                } onCancel: {
                    Task { @MainActor in
                        backend.sheetCancelled = true
                        backend.clickInSheet(false)
                    }
                }
            },
            approve: { request, op, params in
                try await approvals.approve(request: request, op: op, params: try JSONEncoder().encode(params), team: "team_a")
            },
            pause: { _ in },
            watchPause: { _ in try await backend.nextWatchCheck() })
    }

    @Test func aYesOnTheMacAfterThePhoneAnsweredGoesOnWithTheOpsAnswer() async throws {
        let backend = Backend()
        let creating = Task { try await flow(backend).create(name: "cloud-chats", startedByPerson: true) }
        while backend.sheetAnswer == nil { await Task.yield() }
        backend.answeredOnPhone = true
        backend.clickInSheet(true)
        let made = try await creating.value
        #expect(made["id"]?.stringValue == "vm_1")
        #expect(backend.feedAnswers == 0, "a hold answered on the phone was answered again")
    }

    @Test(arguments: [false, true])
    func aHoldOfAnotherTeamStillFails(answeredOnPhone: Bool) async throws {
        let backend = Backend()
        backend.itemTeam = "team_b"
        let creating = Task { try await flow(backend).create(name: "cloud-chats", startedByPerson: true) }
        while backend.sheetAnswer == nil { await Task.yield() }
        backend.answeredOnPhone = answeredOnPhone
        backend.clickInSheet(true)
        await #expect(throws: CloudApprovalAnswer.Failure.mismatch(request: "apr_1", reason: CloudApprovalAnswer.closedItem)) {
            try await creating.value
        }
        #expect(backend.feedAnswers == 0)
    }
}
