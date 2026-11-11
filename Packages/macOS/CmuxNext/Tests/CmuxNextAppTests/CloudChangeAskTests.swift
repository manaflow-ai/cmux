import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCloudUI
import Foundation
import Testing

/// A machine change an agent or a script asked for (`cmux vm fork`, `resize`, `snapshot-machine`) waits for
/// the person's Allow in the cmux window. Before, its run waited 30 s in silence and then answered
/// `pending` (the CLI exited 0), so a declined change read as done and a fork never named its machine.
/// Now the run answers at once that it waits for the person, with the dialog's id; the same ask again
/// joins that run (no second dialog or change) and answers its end: the new machine, or a refusal.
@MainActor
struct CloudChangeAskTests {
    /// A dialog the test answers: shown as dialog 42, its answer given by `answer(_:)`.
    @MainActor final class Dialog {
        let answers: AsyncStream<Bool>
        let continuation: AsyncStream<Bool>.Continuation
        var shown = 0
        init() { (answers, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1)) }
        func answer(_ allowed: Bool) { continuation.yield(allowed) }
        func ask(_ shown: @escaping @MainActor (Int) -> Void) -> @MainActor () async -> Bool {
            { [self] in
                self.shown += 1
                shown(42)
                for await allowed in answers { return allowed }
                return false
            }
        }
    }

    /// One `action.run` of a fork (``CloudHandlers/change``) from `origin`; `forks` counts the changes made.
    static func fork(_ f: (services: AppServices, context: AppActionContext, session: CloudMachineSession), _ dialog: Dialog,
                     origin: ActionOrigin = .cli, forks: Counter) throws -> ActionResultWork {
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: f.session.machineID), origin: origin)
        let source = f.session.machineID
        let run = f.services.registry.capturingRun {
            CloudHandlers.change("fork machine", "palette.cloud.fork", invocation, f.services.registry, f.context,
                                 pending: ["source_machine_id": .string(source)], ask: dialog.ask) { allow in
                guard await allow() else { throw CloudMachineCreateFlow.Failure.declined }
                forks.value += 1
                return CloudAnswer(title: "", text: "", fields: CloudHandlers.machineFields("vm-forked", ["source_machine_id": .string(source)]))
            }
        }
        return try #require(run.results.first)
    }

    @MainActor final class Counter { var value = 0 }

    @Test func aScriptsForkSaysItWaitsForThePersonThenAnswersTheNewMachine() async throws {
        let f = CloudCLITargetTests.fixture(), dialog = Dialog(), forks = Counter()
        guard case .success(let waiting) = await Self.fork(f, dialog, forks: forks).value else {
            return Issue.record("the first answer failed")
        }
        #expect(waiting["pending"] == .bool(true))
        #expect(waiting["waiting_for"] == .string("person"))
        #expect(waiting["dialog_id"] == .string("42"))
        #expect(waiting["ask_again_joins"] == .bool(true))
        // The same ask again joins the run: no second dialog, and the end once the person allows.
        let joined = try Self.fork(f, dialog, forks: forks)
        dialog.answer(true)
        guard case .success(let forked) = await joined.value else { return Issue.record("the allowed fork failed") }
        #expect(forked["machine_id"] == .string("vm-forked"))
        #expect(forked["source_machine_id"] == .string(f.session.machineID))
        #expect(forked["pending"] == nil)
        #expect(dialog.shown == 1)
        #expect(forks.value == 1)
    }

    @Test func dontAllowEndsTheRunRefused() async throws {
        let f = CloudCLITargetTests.fixture(), dialog = Dialog(), forks = Counter()
        guard case .success = await Self.fork(f, dialog, forks: forks).value else { return Issue.record("the first answer failed") }
        let joined = try Self.fork(f, dialog, forks: forks)
        dialog.answer(false)
        guard case .failure(let failure) = await joined.value else { return Issue.record("a declined change answered success") }
        #expect(failure.message == CloudChangeRequest.declined)
        #expect(forks.value == 0)
    }

    /// The person's own run asks nothing and answers the change itself.
    @Test func thePersonsOwnRunAsksNothing() async throws {
        let f = CloudCLITargetTests.fixture(), dialog = Dialog(), forks = Counter()
        guard case .success(let forked) = await Self.fork(f, dialog, origin: .user, forks: forks).value else {
            return Issue.record("the person's fork failed")
        }
        #expect(forked["machine_id"] == .string("vm-forked"))
        #expect(dialog.shown == 0)
    }
}
