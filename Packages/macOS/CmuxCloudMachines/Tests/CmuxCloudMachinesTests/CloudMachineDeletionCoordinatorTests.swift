import Foundation
import Testing
@testable import CmuxCloudMachines

/// Behavior of the real deletion owner, alone and with the create owner, without an app or process.
@MainActor
struct CloudMachineDeletionCoordinatorTests {
    private func makeCreates() -> CloudMachineCreateCoordinator {
        CloudMachineCreateCoordinator(
            output: CloudMachineCreateOutput(legacyCreatedFormat: "Created Cloud VM %@"),
            now: { Date(timeIntervalSince1970: 123) }
        )
    }

    private func request() -> CloudMachineCreateRequest {
        let workspaceID = UUID()
        return CloudMachineCreateRequest(
            arguments: ["vm", "new", "--workspace", workspaceID.uuidString],
            isBaseSetup: false, presentationWorkspaceID: workspaceID, retainsPendingProjection: true
        )
    }

    private func completion(machine: String?, cancelled: Bool = false) -> CloudMachineCreateCompletion {
        CloudMachineCreateCompletion(
            succeeded: !cancelled, wasCancelled: cancelled, output: "", failureOutput: "",
            machineID: machine, workspaceID: nil
        )
    }

    @Test func pendingDeletionIgnoresOtherMachinesOutcomes() {
        let owner = CloudMachineDeletionCoordinator()
        #expect(owner.begin("doomed"))
        #expect(owner.projection.hiddenMachineIDs == ["doomed"])
        #expect(owner.projection.pendingMachineIDs == ["doomed"])
        #expect(owner.isPending("doomed"))
        #expect(owner.finish("other", result: .failed) == .ignored, "an unrelated outcome changes nothing")
        #expect(owner.projection.hiddenMachineIDs == ["doomed"])
        #expect(owner.projection.pendingMachineIDs == ["doomed"])
    }

    @Test(arguments: [CloudMachineDeletionResult.deleted, .notFound])
    func confirmedDeletionStaysHiddenUntilTheAccountEnds(result: CloudMachineDeletionResult) {
        let owner = CloudMachineDeletionCoordinator()
        owner.begin("gone")
        #expect(owner.finish("gone", result: result) == .retired)
        #expect(!owner.isPending("gone"))
        #expect(owner.projection.pendingMachineIDs.isEmpty, "a confirmed deletion has nothing to roll back")
        // One list's fresh read can omit the machine while another list still shows an
        // older read. Provider IDs are never reused, so only the account's end unhides it.
        #expect(owner.projection.hiddenMachineIDs == ["gone"])
        #expect(!owner.begin("gone"))

        #expect(owner.endAccount())
        #expect(owner.projection.hiddenMachineIDs.isEmpty)
    }

    @Test func failedDeletionRestoresOnlyThatMachineAndCanBeRetried() {
        let owner = CloudMachineDeletionCoordinator()
        owner.begin("fails")
        owner.begin("other")
        #expect(owner.finish("fails", result: .failed) == .restored)
        #expect(owner.projection.hiddenMachineIDs == ["other"])
        #expect(owner.projection.pendingMachineIDs == ["other"])
        #expect(owner.finish("fails", result: .deleted) == .ignored, "a late duplicate must not hide the restored row")
        #expect(owner.projection.hiddenMachineIDs == ["other"])
        #expect(owner.begin("fails"), "the person can delete again after a failure")
    }

    @Test func doubleDeleteIsANoOpBeforeAndAfterConfirmation() {
        let owner = CloudMachineDeletionCoordinator()
        #expect(owner.begin("twice"))
        #expect(!owner.begin("twice"))
        #expect(!owner.begin(""))
        #expect(owner.finish("twice", result: .deleted) == .retired)
        #expect(owner.finish("twice", result: .failed) == .ignored, "a second request's failure must not restore a deleted machine")
        #expect(!owner.begin("twice"))
        #expect(owner.projection.hiddenMachineIDs == ["twice"])
    }

    @Test func deletingAPendingCreateStopsItWithoutASecondDestroy() throws {
        let creates = makeCreates()
        let deletions = CloudMachineDeletionCoordinator()
        let attempt = creates.reserve(request())
        _ = creates.receive("OK machine=young\n", from: attempt)
        let pendingID = try #require(creates.projection.operations.first?.id)

        #expect(deletions.begin("young"))
        let retired = creates.retireCreates(producing: "young")
        #expect(retired.cancelOperationIDs == [pendingID])
        #expect(retired.closedOperations.map(\.id) == [pendingID])
        #expect(retired.cleanupMachineIDs.isEmpty, "deletion already owns the destroy request")
        #expect(creates.projection.operations.isEmpty)

        // The stopped create's late receipts never issue another destroy.
        #expect(creates.receive("OK machine=young\n", from: attempt).cleanupMachineIDs.isEmpty)
        let late = creates.finish(completion(machine: "young", cancelled: true), from: attempt)
        #expect(late.cleanupMachineIDs.isEmpty)
        #expect(late.finished == nil)
        #expect(creates.retireCreates(producing: "young").cancelOperationIDs.isEmpty)
    }

    @Test(arguments: [false, true])
    func receiptAfterDeletionBeganRetiresTheCreate(atCompletion: Bool) {
        let creates = makeCreates()
        let deletions = CloudMachineDeletionCoordinator()
        let attempt = creates.reserve(request())
        #expect(deletions.begin("early"))
        #expect(creates.retireCreates(producing: "early").cancelOperationIDs.isEmpty)

        let transition = atCompletion
            ? creates.finish(completion(machine: "early"), from: attempt)
            : creates.receive("OK machine=early\n", from: attempt)
        #expect(transition.cancelOperationIDs == (atCompletion ? [] : [attempt.operationID]))
        #expect(transition.closedOperations.map(\.id) == [attempt.operationID])
        #expect(transition.cleanupMachineIDs.isEmpty)
        #expect(transition.finished == nil, "a deleted machine must never open")
        #expect(creates.projection.operations.isEmpty)
        #expect(creates.finish(completion(machine: "early"), from: attempt).cleanupMachineIDs.isEmpty)
    }

    @Test func receiptAfterAFailedDeletionKeepsTheRestoredMachine() {
        let creates = makeCreates()
        let deletions = CloudMachineDeletionCoordinator()
        let attempt = creates.reserve(request())
        #expect(deletions.begin("survivor"))
        _ = creates.retireCreates(producing: "survivor")
        #expect(deletions.finish("survivor", result: .failed) == .restored)
        creates.machineDeletionFailed("survivor")

        let receipt = creates.receive("OK machine=survivor\n", from: attempt)
        #expect(receipt.cancelOperationIDs.isEmpty, "the restored machine is still this create's")
        #expect(receipt.closedOperations.isEmpty)
        #expect(creates.projection.adoptedOperationIDs["survivor"] == attempt.operationID)
        // Cancelling that create later still cleans its machine up, once.
        #expect(creates.cancel(attempt.operationID).cleanupMachineIDs == ["survivor"])
        #expect(creates.finish(completion(machine: "survivor", cancelled: true), from: attempt).cleanupMachineIDs.isEmpty)
    }

    @Test func createRetiredByAFailedDeletionNeverRetriesTheDestroy() {
        let creates = makeCreates()
        let deletions = CloudMachineDeletionCoordinator()
        let attempt = creates.reserve(request())
        _ = creates.receive("OK machine=kept\n", from: attempt)
        #expect(deletions.begin("kept"))
        #expect(creates.retireCreates(producing: "kept").cancelOperationIDs == [attempt.operationID])
        #expect(deletions.finish("kept", result: .failed) == .restored)
        creates.machineDeletionFailed("kept")

        // The person saw the delete fail and the machine come back; its stopped
        // create's late receipts must not delete it again on their own.
        #expect(creates.receive("OK machine=kept\n", from: attempt).cleanupMachineIDs.isEmpty)
        let late = creates.finish(completion(machine: "kept", cancelled: true), from: attempt)
        #expect(late.cleanupMachineIDs.isEmpty)
        #expect(late.finished == nil)
    }

    @Test func cancelledCreateCleanupJoinsDeletionOnce() {
        let creates = makeCreates()
        let deletions = CloudMachineDeletionCoordinator()
        let attempt = creates.reserve(request())
        _ = creates.receive("OK machine=abandoned\n", from: attempt)

        let cancelled = creates.cancel(attempt.operationID)
        #expect(cancelled.cleanupMachineIDs == ["abandoned"])
        // The adapter routes cleanup through deletion, which hides the machine once.
        #expect(deletions.begin("abandoned"))
        #expect(creates.retireCreates(producing: "abandoned").cancelOperationIDs.isEmpty)
        #expect(!deletions.begin("abandoned"))
        #expect(deletions.projection.hiddenMachineIDs == ["abandoned"])
    }

    @Test func accountTransitionClearsDeletionsWithoutRollback() {
        let owner = CloudMachineDeletionCoordinator()
        owner.begin("in-flight")
        owner.begin("confirmed")
        _ = owner.finish("confirmed", result: .deleted)

        #expect(owner.endAccount())
        #expect(owner.projection.hiddenMachineIDs.isEmpty)
        #expect(owner.projection.pendingMachineIDs.isEmpty)
        #expect(!owner.endAccount())
        #expect(owner.finish("in-flight", result: .failed) == .ignored, "the departed account's failure must not alert")
        #expect(owner.finish("in-flight", result: .deleted) == .ignored)
        #expect(owner.projection.hiddenMachineIDs.isEmpty)

        // The next account starts clean and keeps its own confirmed deletions.
        #expect(owner.begin("next"))
        #expect(owner.begin("confirmed"), "a departed account's deletion never blocks the next account")
        _ = owner.finish("next", result: .deleted)
        _ = owner.finish("confirmed", result: .failed)
        #expect(owner.projection.hiddenMachineIDs == ["next"])
    }
}
