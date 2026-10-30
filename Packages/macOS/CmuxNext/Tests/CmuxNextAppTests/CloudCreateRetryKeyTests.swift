@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// A Cloud create's Retry is the same create (cmuxterm-hq#4709): the app-server path sends the
/// creation's one idempotency key again, to the team of its first send, so a create whose answer
/// was lost answers its first machine instead of making a second one. A new create is a new key.
@MainActor @Suite struct CloudCreateRetryKeyTests {
    /// The backend's create ledger: one machine per (team, key), the same machine for a repeat.
    @MainActor final class Backend {
        var team = "team_a"
        var machines: [String: String] = [:]
        var keys: [String?] = []
        /// Answers this many calls with `approval.pending` before creating.
        var pending = 0
        /// The next create happens, but its answer is lost on the way back.
        var loseNextAnswer = false

        func call(_ key: String?) throws -> JSONValue {
            keys.append(key)
            if pending > 0 {
                pending -= 1
                throw CloudAppOpFailure(code: CloudAppOpFailure.approvalPending, message: "", details: .object(["request": .string("req_1")]))
            }
            let slot = "\(team)|\(key ?? "")"
            let id = machines[slot] ?? "vm_\(machines.count + 1)"
            machines[slot] = id
            if loseNextAnswer {
                loseNextAnswer = false
                throw URLError(.networkConnectionLost)
            }
            return .object(["machine": .object(["id": .string(id)])])
        }
    }

    func flow(_ backend: Backend) -> CloudMachineCreateFlow {
        CloudMachineCreateFlow(run: { _, _, key, _ in try await MainActor.run { try backend.call(key) } },
                               confirm: { _ in true },
                               approve: { _, _, _ in },
                               pause: { _ in })
    }

    @Test func aRetryAfterALostAnswerSendsTheSameKeyAndGetsTheFirstMachine() async throws {
        let backend = Backend()
        let request = CloudMachineRequest()
        backend.loseNextAnswer = true
        await #expect(throws: URLError.self) {
            _ = try await flow(backend).create(name: nil, startedByPerson: false, key: request.idempotencyKey)
        }
        let retried = try await flow(backend).create(name: nil, startedByPerson: false, key: request.idempotencyKey)
        #expect(retried["id"]?.stringValue == "vm_1")
        #expect(backend.machines.count == 1, "the Retry made a second machine: \(backend.machines)")
        #expect(backend.keys == [request.idempotencyKey, request.idempotencyKey])
    }

    @Test func aRetryAfterStillPendingSendsTheSameKey() async throws {
        let backend = Backend()
        let request = CloudMachineRequest()
        backend.pending = 1 + 8 + 1
        await #expect(throws: CloudMachineCreateFlow.Failure.stillPending(request: "req_1")) {
            _ = try await flow(backend).create(name: nil, startedByPerson: false, key: request.idempotencyKey)
        }
        backend.pending = 0
        let retried = try await flow(backend).create(name: nil, startedByPerson: false, key: request.idempotencyKey)
        #expect(retried["id"]?.stringValue == "vm_1")
        #expect(Set(backend.keys) == [request.idempotencyKey], "a call went out with another key: \(backend.keys)")
        #expect(backend.machines.count == 1)
    }

    @Test func aNewCreateIsANewKeyAndANewMachine() async throws {
        let backend = Backend()
        let first = CloudMachineRequest(), second = CloudMachineRequest()
        #expect(first.idempotencyKey != second.idempotencyKey)
        _ = try await flow(backend).create(name: nil, startedByPerson: false, key: first.idempotencyKey)
        _ = try await flow(backend).create(name: nil, startedByPerson: false, key: second.idempotencyKey)
        #expect(backend.machines.count == 2)
    }

    @Test func aRetryStaysWithTheFirstSendsTeamAndIsRefusedInAnother() throws {
        var request = CloudMachineRequest()
        #expect(try CloudService.appServerTeam(current: "team_b", request: request) == "team_b", "an unsent create takes the current team")
        request.wasSent = true
        request.team = "team_a"
        #expect(try CloudService.appServerTeam(current: "team_a", request: request) == "team_a")
        #expect(throws: ActionFailure(message: CloudStrings.createRetryOtherTeam)) {
            try CloudService.appServerTeam(current: "team_b", request: request)
        }
    }

    /// The flow's relay call pinned to team_a (``CloudService/pinnedRun(team:currentTeam:sent:ops:)``), over `backend`.
    func pinnedFlow(_ backend: Backend, sends: Sends) -> CloudMachineCreateFlow {
        CloudMachineCreateFlow(run: CloudService.pinnedRun(team: "team_a", currentTeam: { await MainActor.run { backend.team } },
                                                           sent: { sends.count += 1 },
                                                           ops: { _, _, key, _ in try await MainActor.run { try backend.call(key) } }),
                               confirm: { _ in true }, approve: { _, _, _ in }, pause: { _ in })
    }

    @MainActor final class Sends { var count = 0 }

    @Test func aTeamSwitchBeforeTheFirstSendSendsNothing() async throws {
        let backend = Backend(), sends = Sends()
        backend.team = "team_b"
        await #expect(throws: ActionFailure(message: CloudStrings.createRetryOtherTeam)) {
            _ = try await pinnedFlow(backend, sends: sends).create(name: nil, startedByPerson: false, key: "k1")
        }
        #expect(backend.keys.isEmpty, "a call went out to the other team")
        #expect(sends.count == 0, "the request was marked sent")
    }

    @Test func aTeamSwitchDuringApprovalRetriesStopsTheRetries() async throws {
        let backend = Backend(), sends = Sends()
        backend.pending = 3
        let flow = CloudMachineCreateFlow(run: CloudService.pinnedRun(team: "team_a", currentTeam: { await MainActor.run { backend.team } },
                                                                      sent: { sends.count += 1 },
                                                                      ops: { _, _, key, _ in try await MainActor.run { try backend.call(key) } }),
                                          confirm: { _ in true }, approve: { _, _, _ in },
                                          // The install switches teams during the first retry's backoff.
                                          pause: { _ in await MainActor.run { backend.team = "team_b" } })
        await #expect(throws: ActionFailure(message: CloudStrings.createRetryOtherTeam)) {
            _ = try await flow.create(name: nil, startedByPerson: false, key: "k1")
        }
        #expect(backend.keys == ["k1", "k1"], "a retry went out after the switch: \(backend.keys)")
        #expect(backend.machines.isEmpty)
    }

    @Test func theCreationKeepsItsKeyAndTeamAcrossARestart() {
        let creation = CloudMachineCreation(windowID: nil)
        let key = creation.request.idempotencyKey
        creation.markRequestSent(team: "team_a")
        creation.restart()
        creation.markRequestSent(team: "team_b")
        #expect(creation.request.idempotencyKey == key)
        #expect(creation.request.team == "team_a", "a later send re-pinned the team")
        #expect(creation.request.wasSent)
    }

    @MainActor final class Approvals { var answered: [String] = [] }

    @Test func aRetryWhileTheApprovedCreateStillRunsWaitsInsteadOfAnsweringAgain() async throws {
        let backend = Backend(), approvals = Approvals()
        let creation = CloudMachineCreation(windowID: nil)
        let key = creation.request.idempotencyKey
        func flow() -> CloudMachineCreateFlow {
            CloudMachineCreateFlow(run: { _, _, key, _ in try await MainActor.run { try backend.call(key) } },
                                   confirm: { _ in true },
                                   approve: { request, _, _ in
                                       // The feed item closes with its answer: a second answer is a mismatch.
                                       guard !approvals.answered.contains(request) else {
                                           throw CloudAppOpFailure(code: "cmux.cloud.approval_mismatch", message: "")
                                       }
                                       approvals.answered.append(request)
                                   },
                                   pause: { _ in })
        }
        backend.pending = 1 + 8 + 1
        await #expect(throws: CloudMachineCreateFlow.Failure.stillPending(request: "req_1")) {
            _ = try await flow().create(name: nil, startedByPerson: false, key: key, onApproved: { creation.markApproved($0, key: key) })
        }
        #expect(creation.request.approvedRequest == "req_1")
        // The approved create is still running in the backend when the person clicks Retry.
        backend.pending = 2
        let retried = try await flow().create(name: nil, startedByPerson: false, key: key, approved: creation.request.approvedRequest,
                                              onApproved: { creation.markApproved($0, key: key) })
        #expect(retried["id"]?.stringValue == "vm_1")
        #expect(approvals.answered == ["req_1"], "the Retry answered the closed approval again")
        #expect(backend.machines.count == 1)
    }

    @Test func aRefusalThatMadeNoMachineGivesTheRetryANewKey() {
        for code in ["cmux.cloud.quota_exceeded", "cloud.quota.exceeded", CloudAppOpFailure.planRequired, "cmux.cloud.size_locked",
                     "cmux.cloud.approval_denied", "cmux.cloud.approval_expired", "approval.expired",
                     "cmux.cloud.secrets_unavailable", "cloud.environment.secrets_unavailable", "cmux.cloud.no_snapshot_configured", "cmux.cloud.not_found"] {
            #expect(CloudService.isDefinitiveRefusal(CloudAppOpFailure(code: code, message: "")), "\(code)")
        }
        for code in [CloudAppOpFailure.approvalPending, "cmux.cloud.relay_unavailable", "cmux.cloud.bad_response", "cmux.cloud.failed"] {
            #expect(!CloudService.isDefinitiveRefusal(CloudAppOpFailure(code: code, message: "")), "an uncertain outcome lost its key: \(code)")
        }
        let creation = CloudMachineCreation(windowID: nil)
        let key = creation.request.idempotencyKey
        creation.markRequestSent(team: "team_a")
        creation.markApproved("req_1", key: key)
        creation.renewKey(replacing: key)
        #expect(creation.request.idempotencyKey != key)
        #expect(!creation.request.wasSent && creation.request.team == nil && creation.request.approvedRequest == nil)
    }

    @Test func aLateRefusalOrApprovalForAnOlderKeyLeavesTheCurrentKeyAlone() {
        let creation = CloudMachineCreation(windowID: nil)
        let old = creation.request.idempotencyKey
        creation.renewKey(replacing: old)
        let current = creation.request.idempotencyKey
        creation.markRequestSent(team: "team_a")
        // The superseded attempt's answers arrive after the Retry took the new key.
        creation.renewKey(replacing: old)
        creation.markApproved("req_old", key: old)
        #expect(creation.request.idempotencyKey == current, "a late refusal replaced the key the Retry sent")
        #expect(creation.request.wasSent && creation.request.team == "team_a")
        #expect(creation.request.approvedRequest == nil)
    }

    @Test func aRetryAfterAnAnswerItNeverRecordedWaitsInsteadOfFailing() async throws {
        let backend = Backend()
        backend.pending = 3
        // The first attempt answered req_1 and was cancelled before recording it: the item is closed.
        let flow = CloudMachineCreateFlow(run: { _, _, key, _ in try await MainActor.run { try backend.call(key) } },
                                          confirm: { _ in true },
                                          approve: { request, _, _ in throw CloudApprovalAnswer.Failure.mismatch(request: request, reason: "state") },
                                          pause: { _ in })
        let machine = try await flow.create(name: nil, startedByPerson: false, key: "k1")
        #expect(machine["id"]?.stringValue == "vm_1")
        #expect(backend.machines.count == 1)
        #expect(CloudMachineCreateFlow.alreadyAnswered(.mismatch(request: "r", reason: "state"), request: "r", answeredEarlier: false))
        #expect(!CloudMachineCreateFlow.alreadyAnswered(.mismatch(request: "r", reason: "params"), request: "r", answeredEarlier: true))
        #expect(!CloudMachineCreateFlow.alreadyAnswered(.notInFeed(request: "r"), request: "r", answeredEarlier: true))
        #expect(!CloudMachineCreateFlow.alreadyAnswered(.mismatch(request: "other", reason: "state"), request: "r", answeredEarlier: true))
        // A closed feed item counts only after this key began answering the request.
        #expect(CloudMachineCreateFlow.alreadyAnswered(.mismatch(request: "r", reason: CloudApprovalAnswer.closedItem), request: "r", answeredEarlier: true))
        #expect(!CloudMachineCreateFlow.alreadyAnswered(.mismatch(request: "r", reason: CloudApprovalAnswer.closedItem), request: "r", answeredEarlier: false))
    }

    @Test func aRetryCancelledMidAnswerWaitsForTheRunningApprovedOp() async throws {
        let backend = Backend()
        backend.pending = 3
        let creation = CloudMachineCreation(windowID: nil)
        let key = creation.request.idempotencyKey
        // The first attempt marked req_1 as being answered, then was cancelled; the approval still
        // reads pending (its op runs) but its feed item is closed.
        creation.markAnswering("req_1", key: key)
        let flow = CloudMachineCreateFlow(run: { _, _, key, _ in try await MainActor.run { try backend.call(key) } },
                                          confirm: { _ in true },
                                          approve: { request, _, _ in throw CloudApprovalAnswer.Failure.mismatch(request: request, reason: CloudApprovalAnswer.closedItem) },
                                          pause: { _ in })
        let machine = try await flow.create(name: nil, startedByPerson: false, key: key, answering: creation.request.answeringRequest)
        #expect(machine["id"]?.stringValue == "vm_1")
        #expect(backend.machines.count == 1)
        creation.renewKey(replacing: key)
        #expect(creation.request.answeringRequest == nil)
    }
}
