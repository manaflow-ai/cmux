@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemonService
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
                               approve: { _, _ in },
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
}
