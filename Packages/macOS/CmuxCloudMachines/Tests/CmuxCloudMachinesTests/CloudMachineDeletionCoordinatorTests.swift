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

    @Test func pendingDeletionStaysHiddenAcrossEveryRefreshUntilItsOutcome() {
        let owner = CloudMachineDeletionCoordinator()
        #expect(owner.begin("doomed"))
        #expect(owner.projection.hiddenMachineIDs == ["doomed"])
        #expect(owner.isPending("doomed"))

        // Polls that started before, during, and after the request never resurrect the row.
        for fleet: Set<String> in [["doomed", "kept"], [], ["kept"], ["doomed"]] {
            #expect(!owner.reconcile(owner.beginListing(), machineIDs: fleet))
            #expect(owner.projection.hiddenMachineIDs == ["doomed"])
        }
    }

    @Test(arguments: [CloudMachineDeletionResult.deleted, .notFound])
    func confirmedDeletionRetiresWithoutFlicker(result: CloudMachineDeletionResult) {
        let owner = CloudMachineDeletionCoordinator()
        owner.begin("gone")
        let startedBeforeConfirmation = owner.beginListing()
        #expect(owner.finish("gone", result: result) == .retired)
        #expect(!owner.isPending("gone"))
        #expect(owner.projection.hiddenMachineIDs == ["gone"])

        // A stale read and a lagging backend both still list the machine.
        #expect(!owner.reconcile(startedBeforeConfirmation, machineIDs: ["gone"]))
        #expect(!owner.reconcile(startedBeforeConfirmation, machineIDs: []))
        #expect(!owner.reconcile(owner.beginListing(), machineIDs: ["gone"]))
        #expect(owner.projection.hiddenMachineIDs == ["gone"])

        #expect(owner.reconcile(owner.beginListing(), machineIDs: []))
        #expect(owner.projection.hiddenMachineIDs.isEmpty)
    }

    @Test func failedDeletionRestoresOnlyThatMachineAndCanBeRetried() {
        let owner = CloudMachineDeletionCoordinator()
        owner.begin("fails")
        owner.begin("other")
        #expect(owner.finish("fails", result: .failed) == .restored)
        #expect(owner.projection.hiddenMachineIDs == ["other"])
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
        let oldListing = owner.beginListing()

        #expect(owner.endAccount())
        #expect(owner.projection.hiddenMachineIDs.isEmpty)
        #expect(!owner.endAccount())
        #expect(owner.finish("in-flight", result: .failed) == .ignored, "the departed account's failure must not alert")
        #expect(owner.finish("in-flight", result: .deleted) == .ignored)
        #expect(owner.projection.hiddenMachineIDs.isEmpty)

        // The next account starts clean, and the old account's read cannot retire its deletions.
        #expect(owner.begin("next"))
        _ = owner.finish("next", result: .deleted)
        #expect(!owner.reconcile(oldListing, machineIDs: []))
        #expect(owner.projection.hiddenMachineIDs == ["next"])
    }
}
