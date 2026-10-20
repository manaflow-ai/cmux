import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

@MainActor
@Suite("SplitLayoutModel")
struct SplitLayoutModelTests {
    private struct StubTransfer: Equatable {
        let token: Int
    }

    @Test("starts idle, matching the legacy stored-property defaults")
    func initialState() {
        let model = SplitLayoutModel<StubTransfer>()
        #expect(model.isProgrammaticSplit == false)
        #expect(model.detachingTabIds.isEmpty)
        #expect(model.pendingDetachedSurfaces.isEmpty)
        #expect(model.activeDetachCloseTransactions == 0)
        #expect(model.isDetachingCloseTransaction == false)
    }

    @Test("detach bookkeeping round-trips through the workspace's flow shape")
    func detachFlowRoundtrip() {
        let model = SplitLayoutModel<StubTransfer>()
        let tabId = TabID()

        model.detachingTabIds.insert(tabId)
        model.pendingDetachedSurfaces[tabId] = StubTransfer(token: 3)
        model.activeDetachCloseTransactions += 1
        #expect(model.isDetachingCloseTransaction)
        #expect(model.pendingDetachedSurfaces[tabId] == StubTransfer(token: 3))

        let detached = model.pendingDetachedSurfaces.removeValue(forKey: tabId)
        #expect(detached == StubTransfer(token: 3))
        #expect(model.detachingTabIds.remove(tabId) != nil)
        model.activeDetachCloseTransactions = max(0, model.activeDetachCloseTransactions - 1)
        #expect(model.isDetachingCloseTransaction == false)
        #expect(model.pendingDetachedSurfaces.isEmpty)
    }

    @Test("the transaction flag tracks the open-transaction count")
    func transactionFlagTracksCount() {
        let model = SplitLayoutModel<StubTransfer>()
        model.activeDetachCloseTransactions += 1
        model.activeDetachCloseTransactions += 1
        #expect(model.isDetachingCloseTransaction)
        model.activeDetachCloseTransactions -= 1
        #expect(model.isDetachingCloseTransaction)
        model.activeDetachCloseTransactions -= 1
        #expect(model.isDetachingCloseTransaction == false)
    }

    @Test("the choreography verbs replay the legacy detachSurface success path")
    func choreographyVerbsSuccessPath() {
        let model = SplitLayoutModel<StubTransfer>()
        let tabId = TabID()

        model.markDetaching(tabId)
        model.openDetachCloseTransaction()
        #expect(model.detachingTabIds == [tabId])
        #expect(model.isDetachingCloseTransaction)

        // The close pipeline consumes the mark and captures the transfer.
        #expect(model.consumeDetachingMark(tabId))
        model.storeDetachedTransfer(StubTransfer(token: 7), for: tabId)

        #expect(model.takeDetachedTransfer(tabId) == StubTransfer(token: 7))
        #expect(model.takeDetachedTransfer(tabId) == nil)
        model.closeDetachCloseTransaction()
        #expect(model.isDetachingCloseTransaction == false)
        #expect(model.detachingTabIds.isEmpty)
        #expect(model.pendingDetachedSurfaces.isEmpty)
    }

    @Test("cancelDetach rolls back the mark and any captured transfer")
    func cancelDetachRollsBack() {
        let model = SplitLayoutModel<StubTransfer>()
        let tabId = TabID()

        model.markDetaching(tabId)
        model.openDetachCloseTransaction()
        model.storeDetachedTransfer(StubTransfer(token: 9), for: tabId)
        model.cancelDetach(tabId)
        model.closeDetachCloseTransaction()

        #expect(model.detachingTabIds.isEmpty)
        #expect(model.pendingDetachedSurfaces.isEmpty)
        #expect(model.isDetachingCloseTransaction == false)
    }

    @Test("consumeDetachingMark honors an open transaction for unmarked tabs")
    func consumeDetachingMarkHonorsTransaction() {
        let model = SplitLayoutModel<StubTransfer>()
        let unmarked = TabID()

        // Legacy short-circuit: `detachingTabIds.remove(tabId) != nil ||
        // isDetachingCloseTransaction`.
        #expect(model.consumeDetachingMark(unmarked) == false)
        model.openDetachCloseTransaction()
        #expect(model.consumeDetachingMark(unmarked))
        model.closeDetachCloseTransaction()
        #expect(model.consumeDetachingMark(unmarked) == false)
    }

    @Test("closeDetachCloseTransaction clamps at zero like the legacy max(0, n-1)")
    func closeTransactionClampsAtZero() {
        let model = SplitLayoutModel<StubTransfer>()
        model.closeDetachCloseTransaction()
        #expect(model.activeDetachCloseTransactions == 0)
        model.openDetachCloseTransaction()
        model.closeDetachCloseTransaction()
        model.closeDetachCloseTransaction()
        #expect(model.activeDetachCloseTransactions == 0)
    }
}
