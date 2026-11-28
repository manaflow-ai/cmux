@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// A Cloud create's `user.ensure` (``CloudMachineCreateFlow/beside``) costs no round trip of its own ahead of the
/// create: it runs beside the create's first call, which the backend holds for the approval, and it is done before
/// the approval is answered (the answer lets the op run, and the machine's bind needs the user record).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CloudCreateBesideTests {
    @MainActor final class Log { var events: [String] = []; var pending = true }

    @Test func theEnsureRunsBesideTheFirstCallAndEndsBeforeTheAnswer() async throws {
        let log = Log()
        // The ensure ends only once the create's first call went out: run one after the other, it never would.
        let (sent, send) = AsyncStream<Void>.makeStream()
        var flow = CloudMachineCreateFlow(
            run: { op, _, _, _ in
                try await MainActor.run {
                    log.events.append(op); send.yield()
                    if log.pending { throw CloudAppOpFailure(code: CloudAppOpFailure.approvalPending, message: "", details: .object(["request": .string("apr_1")])) }
                    return .object(["machine": .object(["id": .string("vm_1")])])
                }
            },
            confirm: { _ in true },
            approve: { request, _, _ in log.events.append("approve " + request); log.pending = false },
            pause: { _ in })
        flow.beside = {
            log.events.append("ensure")
            for await _ in sent { break }
            log.events.append("ensured")
        }
        let made = try await flow.create(name: "dev", startedByPerson: true)
        send.finish()
        #expect(made["id"]?.stringValue == "vm_1")
        #expect(log.events.filter { $0 != "ensure" } == ["cloud.machine.create", "ensured", "approve apr_1", "cloud.machine.create"])
    }

    @Test func aCreateAnsweredAtOnceStillWaitsForTheEnsure() async throws {
        let log = Log()
        log.pending = false
        var flow = CloudMachineCreateFlow(
            run: { op, _, _, _ in await MainActor.run { log.events.append(op) }; return .object(["machine": .object(["id": .string("vm_1")])]) },
            confirm: { _ in true }, approve: { _, _, _ in }, pause: { _ in })
        flow.beside = { await Task.yield(); log.events.append("ensured") }
        _ = try await flow.create(name: "dev", startedByPerson: true)
        #expect(log.events.contains("ensured"), "the create answered before its ensure ended")
    }
}
