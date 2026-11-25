@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
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

        /// The approved create still runs in the backend, which answers it pending meanwhile.
        var running: () -> Bool = { false }
        /// The approval request a pending answer names.
        var request = "req_1"

        func call(_ key: String?) throws -> JSONValue {
            keys.append(key)
            if pending > 0 || running() {
                pending = max(pending - 1, 0)
                throw CloudAppOpFailure(code: CloudAppOpFailure.approvalPending, message: "", details: .object(["request": .string(request)]))
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

    /// The flow's clock: no test waits; each backoff moves it on by its own length.
    @MainActor final class Time {
        var now = ContinuousClock.now
        var waits: [Duration] = []
    }

    /// `flow` on `time`: its waits between same-key retries pass at once, and its deadline reads `time`.
    func timed(_ flow: CloudMachineCreateFlow, _ time: Time) -> CloudMachineCreateFlow {
        var flow = flow
        flow.pause = { attempt in
            let wait = CloudMachineCreateFlow.backoff(attempt)
            time.waits.append(wait)
            time.now += wait
        }
        flow.now = { time.now }
        return flow
    }

    /// The backend makes a machine in 27 to 115 s after the approval (measured), longer than the old 8 retries
    /// (about 40 s) waited: the start failed, and the server finished a machine nobody used.
    @Test func anApprovedCreateTheServerTakesAMinuteOverIsWaitedFor() async throws {
        let backend = Backend(), time = Time()
        let start = time.now
        backend.pending = 1
        backend.running = { time.now - start < .seconds(60) }
        let machine = try await timed(flow(backend), time).create(name: nil, startedByPerson: true, key: "k1")
        #expect(machine["id"]?.stringValue == "vm_1")
        #expect(backend.machines.count == 1)
        #expect(Set(backend.keys) == ["k1"], "a call went out with another key: \(backend.keys)")
        #expect(time.now - start >= .seconds(60))
        #expect(time.waits.prefix(5) == [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(1), .seconds(1)], "the backoff stays short: \(time.waits)")
        #expect(time.waits.allSatisfy { $0 <= .seconds(1) })
    }

    /// A start whose server finishes the approved create 8 s after the answer gets its machine within about a second
    /// of that, not at the next 8 s backoff (measured: the old 1, 2, 4, 8 s waited about 3.5 s past the machine).
    @Test func anApprovedCreateTheServerFinishesSoonIsSeenWithinASecond() async throws {
        let backend = Backend(), time = Time()
        let start = time.now
        backend.pending = 1
        backend.running = { time.now - start < .seconds(8) }
        _ = try await timed(flow(backend), time).create(name: nil, startedByPerson: true, key: "k1")
        let waited = time.now - start
        #expect(waited >= .seconds(8) && waited <= .seconds(9), "the machine was ready at 8 s and seen at \(waited)")
    }

    /// A measured start's `machine` step names the approval's own parts, so a start's `stages_ms` splits the time
    /// between the held first call and the same-key retry (the wait for `user.ensure`, then the answer).
    @Test func aMeasuredStartMarksTheApprovalsParts() async throws {
        let backend = Backend()
        backend.pending = 1
        let (_, record) = try await CloudStartStepRecord.recording { try await flow(backend).create(name: nil, startedByPerson: true, key: "k1") }
        #expect(record.steps.map(\.name) == ["machine.ensure", "machine.approve"], "\(record.steps)")
    }

    /// The backoffs after the approval fill the patience (two minutes) and stop there, however short each one is.
    @Test func theRetriesFillThePatienceAndNoMore() {
        let waits = CloudMachineCreateFlow.waits(within: CloudAppOpRunner.timeout)
        let pauses = (1..<waits).reduce(Duration.zero) { $0 + CloudMachineCreateFlow.backoff($1) }
        #expect(pauses >= CloudAppOpRunner.timeout && pauses < CloudAppOpRunner.timeout + .seconds(2), "\(waits) waits add up to \(pauses)")
        #expect(CloudMachineCreateFlow.waits(within: .zero) == 1)
    }

    @Test func anApprovedCreateStillPendingAfterTwoMinutesEndsStillPendingAndItsRetryGetsTheSameMachine() async throws {
        let backend = Backend(), time = Time()
        let start = time.now
        backend.running = { true }
        let approvals = Approvals()
        await #expect(throws: CloudMachineCreateFlow.Failure.stillPending(request: "req_1")) {
            _ = try await timed(flow(backend), time).create(name: nil, startedByPerson: true, key: "k1", onApproved: { approvals.answered.append($0) })
        }
        #expect(approvals.answered == ["req_1"])
        let waited = time.now - start
        #expect(waited >= .seconds(120) && waited < .seconds(130), "the same-key retries went on for \(waited)")
        #expect(backend.machines.isEmpty)
        // The server finishes the machine; the person's Retry sends the same key and gets it.
        backend.running = { false }
        let retried = try await timed(flow(backend), time).create(name: nil, startedByPerson: true, key: "k1", approved: approvals.answered.last)
        #expect(retried["id"]?.stringValue == "vm_1")
        #expect(Set(backend.keys) == ["k1"] && backend.machines.count == 1)
    }

    @Test func aPendingAnswerForAnotherRequestAfterTheApprovalFailsAtOnce() async throws {
        let backend = Backend(), time = Time()
        backend.running = { true }
        var create = timed(flow(backend), time)
        // The hold answered was req_1; the backend now holds the key for another request.
        create.approve = { _, _, _ in backend.request = "req_2" }
        let held = create
        await #expect(throws: CloudMachineCreateFlow.Failure.stillPending(request: "req_2")) {
            _ = try await held.create(name: nil, startedByPerson: true, key: "k1")
        }
        #expect(time.waits.isEmpty, "it waited for a request nobody answered: \(time.waits)")
        #expect(backend.keys.count == 2)
    }

    @Test func aCancelledStartStopsRetrying() async throws {
        let backend = Backend()
        backend.running = { true }
        var create = flow(backend)
        // The real wait is a clock sleep, which throws once the start's task is cancelled.
        create.pause = { _ in throw CancellationError() }
        let cancelled = create
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.create(name: nil, startedByPerson: true, key: "k1")
        }
        #expect(backend.keys.count == 2, "a retry went out after the cancel: \(backend.keys)")
    }

    /// A person reads the failure's own sentence, not "Something went wrong. Try again." (it was only a `description`).
    @Test func aStillPendingCreateAndAnUnansweredApprovalReadAsTheirOwnSentences() {
        #expect(CloudStrings.errorText(CloudMachineCreateFlow.Failure.stillPending(request: "req_1")) == CloudStrings.createStillPending)
        #expect(CloudStrings.errorText(CloudMachineCreateFlow.Failure.noApprovalRequest) == CloudStrings.createApproveInFeed)
        #expect(CloudStrings.errorText(CloudApprovalAnswer.Failure.notInFeed(request: "req_1")) == CloudStrings.createApproveInFeed)
        #expect(CloudStrings.errorText(CloudApprovalAnswer.Failure.mismatch(request: "req_1", reason: "params")) == CloudStrings.createApprovalMismatch)
        #expect(CloudStrings.createStillPending != PlainErrorText.generic)
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
        backend.running = { true }
        await #expect(throws: CloudMachineCreateFlow.Failure.stillPending(request: "req_1")) {
            _ = try await timed(flow(backend), Time()).create(name: nil, startedByPerson: false, key: request.idempotencyKey)
        }
        backend.running = { false }
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

    @Test func aFailedDurableSentWriteSendsNoCreate() async throws {
        let backend = Backend()
        let flow = CloudMachineCreateFlow(run: CloudService.pinnedRun(team: "team_a", currentTeam: { "team_a" },
            sent: { throw CancellationError() }, ops: { _, _, key, _ in try await MainActor.run { try backend.call(key) } }),
            confirm: { _ in true }, approve: { _, _, _ in }, pause: { _ in })
        await #expect(throws: CancellationError.self) {
            _ = try await flow.create(name: "cloud-chats", startedByPerson: true, key: "lost-answer")
        }
        #expect(backend.keys.isEmpty)
        #expect(backend.machines.isEmpty)
    }

    @Test func aTeamSwitchWhilePersistingTheSendSendsNoCreate() async throws {
        let backend = Backend()
        let flow = CloudMachineCreateFlow(run: CloudService.pinnedRun(team: "team_a", currentTeam: { await MainActor.run { backend.team } },
            sent: { backend.team = "team_b" }, ops: { _, _, key, _ in try await MainActor.run { try backend.call(key) } }),
            confirm: { _ in true }, approve: { _, _, _ in }, pause: { _ in })
        await #expect(throws: ActionFailure.self) {
            _ = try await flow.create(name: "cloud-chats", startedByPerson: true, key: "lost-answer")
        }
        #expect(backend.keys.isEmpty)
    }

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
        backend.running = { true }
        await #expect(throws: CloudMachineCreateFlow.Failure.stillPending(request: "req_1")) {
            _ = try await timed(flow(), Time()).create(name: nil, startedByPerson: false, key: key, onApproved: { creation.markApproved($0, key: key) })
        }
        #expect(creation.request.approvedRequest == "req_1")
        // The approved create is still running in the backend when the person clicks Retry.
        backend.running = { false }
        backend.pending = 2
        let retried = try await flow().create(name: nil, startedByPerson: false, key: key, approved: creation.request.approvedRequest,
                                              onApproved: { creation.markApproved($0, key: key) })
        #expect(retried["id"]?.stringValue == "vm_1")
        #expect(approvals.answered == ["req_1"], "the Retry answered the closed approval again")
        #expect(backend.machines.count == 1)
    }

    @Test func aRefusalThatMadeNoMachineGivesTheRetryANewKey() {
        // Each code's reading is cmux-cloud-start-core's (`machine_create`, with its cases); the app asks it.
        #expect(CloudStartCore().isDefinitiveRefusal(CloudAppOpFailure(code: CloudAppOpFailure.planRequired, message: "")))
        #expect(!CloudStartCore().isDefinitiveRefusal(CloudAppOpFailure(code: CloudAppOpFailure.approvalPending, message: "")))
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
        #expect(CloudApprovalAnswer.Failure.mismatch(request: "r", reason: "state").alreadyAnswered(request: "r", answeredEarlier: false))
        #expect(!CloudApprovalAnswer.Failure.mismatch(request: "r", reason: "params").alreadyAnswered(request: "r", answeredEarlier: true))
        #expect(!CloudApprovalAnswer.Failure.notInFeed(request: "r").alreadyAnswered(request: "r", answeredEarlier: true))
        #expect(!CloudApprovalAnswer.Failure.mismatch(request: "other", reason: "state").alreadyAnswered(request: "r", answeredEarlier: true))
        // A closed feed item counts only after this key began answering the request.
        #expect(CloudApprovalAnswer.Failure.mismatch(request: "r", reason: CloudApprovalAnswer.closedItem).alreadyAnswered(request: "r", answeredEarlier: true))
        #expect(!CloudApprovalAnswer.Failure.mismatch(request: "r", reason: CloudApprovalAnswer.closedItem).alreadyAnswered(request: "r", answeredEarlier: false))
        // This team's closed item (answered elsewhere) goes on without an answer here; another team's never does.
        #expect(CloudApprovalAnswer.Failure.answered(request: "r").answeredElsewhere(request: "r"))
        #expect(!CloudApprovalAnswer.Failure.mismatch(request: "r", reason: CloudApprovalAnswer.closedItem).answeredElsewhere(request: "r"))
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
