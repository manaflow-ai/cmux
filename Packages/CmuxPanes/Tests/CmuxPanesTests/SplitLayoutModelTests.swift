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
}
