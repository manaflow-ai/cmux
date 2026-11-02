@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// A person's create held for approval (G8) shows the "Create a Cloud machine?" sheet. When the
/// person answers that hold elsewhere first (the feed on their phone, the dashboard), the sheet
/// closes and the create goes on with the op's answer; it never waits on a click that is no
/// longer needed. A person who declines in the sheet still sends nothing more.
@MainActor @Suite(.serialized) struct CloudApprovalAnsweredElsewhereTests {
    @MainActor final class Backend {
        var calls = 0
        /// The hold is answered elsewhere: the next same-key call answers the machine.
        var answeredElsewhere = false
        var approved: [String] = []
        var sheetCancelled = false
        var sheetAnswer: CheckedContinuation<Bool, Never>?

        func call() throws -> JSONValue {
            calls += 1
            guard answeredElsewhere else {
                throw CloudAppOpFailure(code: CloudAppOpFailure.approvalPending, message: "", details: .object(["request": .string("apr_1")]))
            }
            return .object(["machine": .object(["id": .string("vm_1")])])
        }
    }

    /// The sheet waits for an answer that only the test (as the person) or a cancellation gives.
    private func flow(_ backend: Backend, watch: Bool = true) -> CloudMachineCreateFlow {
        CloudMachineCreateFlow(
            run: { _, _, _, _ in try await MainActor.run { try backend.call() } },
            confirm: { _ in
                await withTaskCancellationHandler {
                    await withCheckedContinuation { backend.sheetAnswer = $0 }
                } onCancel: {
                    Task { @MainActor in
                        backend.sheetCancelled = true
                        backend.sheetAnswer?.resume(returning: false)
                        backend.sheetAnswer = nil
                    }
                }
            },
            approve: { request, _, _ in
                backend.approved.append(request)
                // The hold already ended elsewhere: the answer finds it closed (``alreadyAnswered``).
                throw CloudApprovalAnswer.Failure.mismatch(request: request, reason: "state")
            },
            pause: { _ in },
            watchPause: watch ? { _ in await Task.yield() } : nil)
    }

    @Test func aHoldAnsweredElsewhereClosesTheSheetAndTheCreateGoesOn() async throws {
        let backend = Backend()
        let creating = Task { try await flow(backend).create(name: "cloud-chats", startedByPerson: true) }
        while backend.sheetAnswer == nil { await Task.yield() }
        backend.answeredElsewhere = true
        let made = try await creating.value
        #expect(made["id"]?.stringValue == "vm_1")
        #expect(backend.sheetCancelled, "the sheet stayed open after the hold was answered elsewhere")
    }

    @Test func aDeclineInTheSheetSendsNothingMore() async throws {
        let backend = Backend()
        let creating = Task { try await flow(backend).create(name: "cloud-chats", startedByPerson: true) }
        while backend.sheetAnswer == nil { await Task.yield() }
        backend.sheetAnswer?.resume(returning: false)
        backend.sheetAnswer = nil
        await #expect(throws: CloudMachineCreateFlow.Failure.declined) { try await creating.value }
        #expect(backend.approved.isEmpty, "a declined sheet still answered the hold")
        let afterDecline = backend.calls
        for _ in 0..<20 { await Task.yield() }
        #expect(backend.calls == afterDecline, "the watch went on calling after the sheet closed")
    }

    @Test func withoutAWatchOnlyTheSheetAnswers() async throws {
        let backend = Backend()
        let creating = Task { try await flow(backend, watch: false).create(name: "cloud-chats", startedByPerson: true) }
        while backend.sheetAnswer == nil { await Task.yield() }
        backend.answeredElsewhere = true
        for _ in 0..<20 { await Task.yield() }
        #expect(backend.calls == 1, "a flow with no watch called again while the sheet was open")
        #expect(!backend.sheetCancelled)
        backend.sheetAnswer?.resume(returning: true)
        backend.sheetAnswer = nil
        let made = try await creating.value
        #expect(made["id"]?.stringValue == "vm_1")
    }
}
