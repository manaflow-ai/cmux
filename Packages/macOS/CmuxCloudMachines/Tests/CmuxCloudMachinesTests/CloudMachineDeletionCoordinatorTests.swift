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

    @Test func closingTheMachinesWorkspacesNeverDestroysItAfterAFailedDeletion() throws {
        let creates = makeCreates()
        let deletions = CloudMachineDeletionCoordinator()
        let bound = request()
        let workspaceID = try #require(bound.presentationWorkspaceID)
        let attempt = creates.reserve(bound)
        // The create bound its workspace to the machine before its receipt was read.
        #expect(deletions.begin("bound"))
        let retired = creates.retireCreates(producing: "bound", presentedIn: [workspaceID])
        #expect(retired.cancelOperationIDs == [attempt.operationID])
        #expect(retired.cleanupMachineIDs.isEmpty)
        // The deletion then closes the machine's workspaces, which finds nothing to cancel.
        #expect(creates.cancelPresentations([workspaceID]).cancelOperationIDs.isEmpty)
        #expect(deletions.finish("bound", result: .failed) == .restored)
        creates.machineDeletionFailed("bound")

        // The person never cancelled that create, so its late receipts must not
        // destroy the machine the failure alert said was kept.
        #expect(creates.receive("OK machine=bound\n", from: attempt).cleanupMachineIDs.isEmpty)
        #expect(creates.finish(completion(machine: "bound", cancelled: true), from: attempt).cleanupMachineIDs.isEmpty)
    }

    @Test func deletionLeavesTheMachinesOwnWorkspacesForTheCallerToClose() throws {
        let creates = makeCreates()
        let deletions = CloudMachineDeletionCoordinator()
        let bound = request()
        let boundWorkspaceID = try #require(bound.presentationWorkspaceID)
        let boundAttempt = creates.reserve(bound)
        let producer = creates.reserve(request())
        _ = creates.receive("OK machine=doomed\n", from: producer)
        let boundProducerRequest = request()
        let boundProducerWorkspaceID = try #require(boundProducerRequest.presentationWorkspaceID)
        let boundProducer = creates.reserve(boundProducerRequest)
        _ = creates.receive("OK machine=doomed\n", from: boundProducer)
        #expect(deletions.begin("doomed"))

        let retired = creates.retireCreates(
            producing: "doomed", presentedIn: [boundWorkspaceID, boundProducerWorkspaceID]
        )
        #expect(Set(retired.cancelOperationIDs) == [boundAttempt.operationID, producer.operationID, boundProducer.operationID])
        // Closing a create's presentation keeps any pane the person added and
        // unbinds it, which would hide it from the deletion's whole-workspace close,
        // even for the create that produced the machine.
        #expect(retired.closedOperations.map(\.id) == [producer.operationID])
        #expect(retired.cleanupMachineIDs.isEmpty, "The deletion owns the machine's destroy request")
    }

    @Test func closingTheMachinesWorkspacesStillCleansUpAnotherMachine() throws {
        let creates = makeCreates()
        let deletions = CloudMachineDeletionCoordinator()
        let bound = request()
        let workspaceID = try #require(bound.presentationWorkspaceID)
        let attempt = creates.reserve(bound)
        #expect(deletions.begin("bound"))
        _ = creates.retireCreates(producing: "bound", presentedIn: [workspaceID])
        _ = creates.cancelPresentations([workspaceID])

        // A machine the stopped create made that nobody is deleting would otherwise leak.
        #expect(creates.receive("OK machine=other\n", from: attempt).cleanupMachineIDs == ["other"])
        #expect(creates.finish(completion(machine: "other", cancelled: true), from: attempt).cleanupMachineIDs.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancelledCreateCleanupFollowsWhenItsReceiptArrived(duringDeletion: Bool) {
        let creates = makeCreates()
        let deletions = CloudMachineDeletionCoordinator()
        let attempt = creates.reserve(request())
        _ = creates.cancel(attempt.operationID)
        #expect(deletions.begin("listed"))
        _ = creates.retireCreates(producing: "listed")

        if duringDeletion {
            #expect(creates.receive("OK machine=listed\n", from: attempt).cleanupMachineIDs.isEmpty, "the deletion owns the destroy")
        }
        #expect(deletions.finish("listed", result: .failed) == .restored)
        creates.machineDeletionFailed("listed")
        let late = creates.finish(completion(machine: "listed", cancelled: true), from: attempt)
        // A receipt seen during the deletion never destroys the machine after it fails.
        // One that first names the machine afterwards carries out the person's cancel.
        #expect(late.cleanupMachineIDs == (duringDeletion ? [] : ["listed"]))
    }

    @Test func accountEndReleasesAPendingDeletionWithoutASecondDestroy() {
        let creates = makeCreates()
        let deletions = CloudMachineDeletionCoordinator()
        let departed = creates.reserve(request())
        #expect(deletions.begin("base"))
        _ = creates.retireCreates(producing: "base")
        #expect(deletions.endAccount())
        _ = creates.endAccount()

        // The departed account's create names the machine its deletion owned.
        #expect(creates.receive("OK machine=base\n", from: departed).cleanupMachineIDs.isEmpty)
        #expect(creates.finish(completion(machine: "base", cancelled: true), from: departed).cleanupMachineIDs.isEmpty)

        // The delete failed on the server after the switch; setting up Base opens the machine.
        let setup = creates.reserve(CloudMachineCreateRequest(
            arguments: ["vm", "base", "open"], isBaseSetup: true, presentationWorkspaceID: nil, retainsPendingProjection: false
        ))
        #expect(creates.receive("OK machine=base\n", from: setup).cancelOperationIDs.isEmpty)
        let opened = creates.finish(completion(machine: "base"), from: setup)
        #expect(opened.finished?.outcome == .created(machineID: "base", workspaceID: nil))
    }

    @Test func cancelledCreateCleanupJoinsDeletionOnce() {
        let creates = makeCreates()
        let deletions = CloudMachineDeletionCoordinator()
        let attempt = creates.reserve(request())
        _ = creates.receive("OK machine=abandoned\n", from: attempt)

        let cancelled = creates.cancel(attempt.operationID)
        #expect(cancelled.cleanupMachineIDs == ["abandoned"])
        // The adapter routes cleanup through deletion, which hides the machine once.
        #expect(deletions.beginCleanup("abandoned"))
        #expect(creates.retireCreates(producing: "abandoned").cancelOperationIDs.isEmpty)
        #expect(!deletions.beginCleanup("abandoned"))
        #expect(!deletions.begin("abandoned"))
        #expect(deletions.projection.hiddenMachineIDs == ["abandoned"])
    }

    @Test func cleanupReportsOnlyItsFirstRequestAndRollsBackLikeADelete() {
        let owner = CloudMachineDeletionCoordinator()
        #expect(owner.beginCleanup("cleanup"))
        #expect(owner.projection.hiddenMachineIDs == ["cleanup"])
        #expect(owner.projection.pendingMachineIDs == ["cleanup"], "a cleanup can still come back")
        #expect(owner.isPending("cleanup"))
        #expect(owner.beginRequest("cleanup"), "the cleanup's request detaches its presentations")
        #expect(!owner.beginRequest("cleanup"), "a joined request detaches nothing again")
        #expect(owner.finish("cleanup", result: .deleted) == .retired)

        #expect(owner.begin("deleted"))
        #expect(!owner.beginRequest("deleted"), "a delete detached when it began")

        // A cleanup whose CLI exits first, or whose account ends, never reports a request.
        #expect(owner.beginCleanup("exited"))
        #expect(owner.finish("exited", result: .failed) == .restored)
        #expect(!owner.beginRequest("exited"))
        #expect(owner.beginCleanup("departed"))
        #expect(owner.endAccount())
        #expect(!owner.beginRequest("departed"))
        #expect(owner.projection.hiddenMachineIDs.isEmpty)
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
