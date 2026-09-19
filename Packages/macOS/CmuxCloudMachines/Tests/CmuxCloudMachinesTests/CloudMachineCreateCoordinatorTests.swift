import Foundation
import Testing
@testable import CmuxCloudMachines

/// Behavior of the real lifecycle owner without launching an app or process.
@MainActor
struct CloudMachineCreateCoordinatorTests {
    private func makeOwner() -> CloudMachineCreateCoordinator {
        CloudMachineCreateCoordinator(
            output: CloudMachineCreateOutput(legacyCreatedFormat: "Created Cloud VM %@"),
            now: { Date(timeIntervalSince1970: 123) }
        )
    }

    private func request(workspaceID: UUID = UUID(), isBase: Bool = false) -> CloudMachineCreateRequest {
        CloudMachineCreateRequest(
            arguments: ["vm", "new", "--workspace", workspaceID.uuidString, "--focus", "false"],
            isBaseSetup: isBase, presentationWorkspaceID: workspaceID, retainsPendingProjection: true
        )
    }

    private func completion(machine: String? = nil, success: Bool = true, cancelled: Bool = false) -> CloudMachineCreateCompletion {
        CloudMachineCreateCompletion(
            succeeded: success, wasCancelled: cancelled, output: "", failureOutput: "unavailable",
            machineID: machine, workspaceID: nil
        )
    }

    @Test func pendingExistsBeforeDelayedCreateResponse() {
        let owner = makeOwner()
        let request = request()
        let attempt = owner.reserve(request)

        #expect(owner.projection.operations.count == 1)
        #expect(owner.projection.operations.first?.id == attempt.operationID)
        #expect(owner.projection.operations.first?.phase == .running)
        #expect(owner.projection.operations.first?.createdMachineID == nil)
        #expect(owner.projection.operations.first?.request == request)
        #expect(owner.projection.operations.first?.startedAt == Date(timeIntervalSince1970: 123))
        #expect(owner.isActive(attempt))

        let transition = owner.finish(completion(machine: "ready"), from: attempt)
        #expect(transition.finished?.outcome == .created(machineID: "ready", workspaceID: nil))
        #expect(owner.projection.operations.first?.id == attempt.operationID)
        #expect(owner.projection.operations.first?.phase == .reconciling(machineID: "ready"))
    }

    @Test(arguments: [false, true])
    func adoptionIsIndependentOfCoalescedRendering(renderBeforeReconcile: Bool) throws {
        let owner = makeOwner()
        let attempt = owner.reserve(request())
        let pendingID = try #require(owner.projection.operations.first?.id)
        _ = owner.finish(completion(machine: "ready"), from: attempt)
        if renderBeforeReconcile {
            #expect(owner.projection.adoptedOperationIDs["ready"] == pendingID)
        }
        #expect(owner.reconcile(machineIDs: ["ready"]))
        #expect(owner.projection.operations.isEmpty)
        #expect(owner.projection.adoptedOperationIDs["ready"] == pendingID)

        // Different windows may receive empty, partial, and repeated snapshots in any order.
        for fleet: Set<String> in [[], ["other"], ["ready"], []] {
            #expect(!owner.reconcile(machineIDs: fleet))
            #expect(owner.projection.adoptedOperationIDs["ready"] == pendingID)
        }
    }

    @Test func earlyReceiptKeepsIdentityBeforeAttachAndThroughFailureToOpen() {
        let owner = makeOwner()
        let attempt = owner.reserve(request())
        _ = owner.receive("OK machine=early\n", from: attempt)
        #expect(owner.projection.adoptedOperationIDs["early"] == attempt.operationID)
        #expect(owner.projection.operations.first?.phase == .running)
        let transition = owner.finish(completion(machine: "early", success: false), from: attempt)
        #expect(transition.finished?.outcome == .createdButOpenFailed(machineID: "early", output: "unavailable"))
        #expect(owner.projection.operations.first?.phase == .failed(output: "unavailable"))
        #expect(owner.retry(attempt.operationID) != nil)
        #expect(owner.projection.operations.first?.createdMachineID == "early", "retry must open the existing VM")
        #expect(owner.cancel(attempt.operationID).cleanupMachineIDs.isEmpty, "cancelling an open must not destroy the committed VM")
        #expect(owner.projection.adoptedOperationIDs["early"] == attempt.operationID)
    }

    @Test func repeatedExplicitCreatesStayDistinctWhenCompletionOrderReverses() {
        let owner = makeOwner()
        let first = owner.reserve(request())
        let second = owner.reserve(request())
        #expect(first.operationID != second.operationID)
        #expect(owner.projection.operations[0].request.arguments != owner.projection.operations[1].request.arguments)
        _ = owner.finish(completion(machine: "second"), from: second)
        #expect(owner.isActive(first))
        _ = owner.finish(completion(machine: "first"), from: first)
        #expect(owner.projection.operations.map(\.id) == [first.operationID, second.operationID])
        owner.reconcile(machineIDs: ["second", "first"])
        #expect(owner.projection.adoptedOperationIDs == ["first": first.operationID, "second": second.operationID])
    }

    @Test func ambiguousFailureRetryReusesScopeAndFencesOldCallbacks() throws {
        let owner = makeOwner()
        let originalRequest = request()
        let first = owner.reserve(originalRequest)
        _ = owner.finish(completion(success: false), from: first)
        #expect(owner.projection.operations.first?.phase == .failed(output: "unavailable"))
        let retry = try #require(owner.retry(first.operationID))
        #expect(retry.operationID == first.operationID)
        #expect(retry != first)
        #expect(owner.projection.operations.first?.request.arguments == originalRequest.arguments)
        #expect(!owner.receive("OK machine=obsolete\n", from: first).changed)
        #expect(owner.finish(completion(machine: "obsolete"), from: first).finished == nil)
        #expect(owner.projection.adoptedOperationIDs.isEmpty)
        #expect(owner.isActive(retry))
        _ = owner.finish(completion(machine: "recovered"), from: retry)
        #expect(owner.projection.adoptedOperationIDs["recovered"] == first.operationID)
    }

    @Test func failedDismissalCannotResurrectAndClosesOnlyItsReservation() {
        let owner = makeOwner()
        let attempt = owner.reserve(request())
        _ = owner.finish(completion(success: false), from: attempt)
        let dismissed = owner.dismiss(attempt.operationID)
        #expect(dismissed.closedOperations.map(\.id) == [attempt.operationID])
        #expect(owner.projection.operations.isEmpty)
        #expect(owner.retry(attempt.operationID) == nil)
        #expect(owner.finish(completion(machine: "obsolete"), from: attempt).finished == nil)
        #expect(owner.projection.adoptedOperationIDs.isEmpty)
    }

    @Test func workspaceOwnedBatchTeardownNeverRequestsPresentationClosure() {
        let owner = makeOwner()
        let workspaceIDs = (0..<100).map { _ in UUID() }
        let attempts = workspaceIDs.map { owner.reserve(request(workspaceID: $0)) }
        let unrelated = owner.reserve(request())
        _ = owner.finish(completion(success: false), from: attempts[0])
        _ = owner.finish(completion(machine: "committed"), from: attempts[1])
        let cancelled = owner.cancelPresentations(Set(workspaceIDs))
        #expect(cancelled.closedOperations.isEmpty)
        #expect(cancelled.cancelOperationIDs.count == 98)
        #expect(owner.projection.operations.map(\.id) == [unrelated.operationID])
        #expect(cancelled.cleanupMachineIDs.isEmpty, "closing a committed projection must not delete its VM")
        #expect(owner.finish(completion(machine: "late"), from: attempts[2]).cleanupMachineIDs == ["late"])
    }

    @Test func splitLateReceiptNeverDeletesAPartialIDAndIsCleanedExactlyOnce() {
        let owner = makeOwner()
        let attempt = owner.reserve(request())
        _ = owner.receive("OK machine=full-", from: attempt)
        #expect(owner.projection.adoptedOperationIDs.isEmpty)
        let cancelled = owner.cancel(attempt.operationID)
        #expect(cancelled.cancelOperationIDs == [attempt.operationID])
        #expect(cancelled.cleanupMachineIDs.isEmpty)
        #expect(owner.receive("identifier\n", from: attempt).cleanupMachineIDs == ["full-identifier"])
        let final = owner.finish(completion(machine: "full-identifier"), from: attempt)
        #expect(final.cleanupMachineIDs.isEmpty)
        #expect(final.finished == nil)
        #expect(owner.projection.operations.isEmpty)
        #expect(owner.projection.adoptedOperationIDs.isEmpty)
    }

    @Test func cancellationRetainsEveryLiveReceiptBeyondTheOldEvictionCap() {
        let owner = makeOwner()
        let attempts = (0..<100).map { _ in owner.reserve(request()) }
        for attempt in attempts { _ = owner.cancel(attempt.operationID) }
        for (index, attempt) in attempts.enumerated() {
            #expect(owner.finish(completion(machine: "late-\(index)"), from: attempt).cleanupMachineIDs == ["late-\(index)"])
        }
    }

    @Test func accountTransitionDropsAliasesAndOldCallbacksCannotChangeTheNewAccount() {
        let owner = makeOwner()
        let completed = owner.reserve(request())
        _ = owner.finish(completion(machine: "old"), from: completed)
        let pending = owner.reserve(request())
        let ended = owner.endAccount()
        #expect(ended.closedOperations.count == 2)
        #expect(owner.projection.adoptedOperationIDs.isEmpty)
        let newAccount = owner.reserve(request())
        let late = owner.finish(completion(machine: "late"), from: pending)
        #expect(late.cleanupMachineIDs == ["late"])
        #expect(late.finished == nil)
        #expect(owner.projection.operations.map(\.id) == [newAccount.operationID])
        #expect(owner.projection.adoptedOperationIDs.isEmpty)
    }

    @Test func cancellingBaseNeverDestroysAnExistingMachine() {
        let owner = makeOwner()
        let base = owner.reserve(request(isBase: true))
        _ = owner.receive("OK machine=base\n", from: base)
        #expect(owner.cancel(base.operationID).cleanupMachineIDs.isEmpty)
        #expect(owner.finish(completion(machine: "base"), from: base).cleanupMachineIDs.isEmpty)
        #expect(owner.projection.adoptedOperationIDs.isEmpty)
    }

    @Test func refusedRetryRemainsRecoverableAndFencesTheRefusedLauncher() throws {
        let owner = makeOwner()
        let first = owner.reserve(request())
        _ = owner.finish(completion(success: false), from: first)
        let second = try #require(owner.retry(first.operationID))
        _ = owner.refuse(second, retryFailure: "sign in")
        #expect(owner.projection.operations.first?.phase == .failed(output: "sign in"))
        #expect(owner.finish(completion(machine: "obsolete"), from: second).finished == nil)
        #expect(owner.retry(first.operationID) != nil)
    }

    @Test func parserDoesNotTreatErrorProseAsAReceipt() {
        let parser = CloudMachineCreateOutput(legacyCreatedFormat: "Created Cloud VM %@")
        #expect(parser.machineID(in: "Error: request for machine=unrelated failed") == nil)
        #expect(parser.machineID(in: "OK machine=real") == "real")
        #expect(parser.failureText(in: "OK machine=real\nError: attach failed") == "Error: attach failed")
    }
}
