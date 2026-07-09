import CmuxSettings
import Testing

@testable import CmuxSettingsUI

@Suite
struct BrowserWebExtensionsCardStateTests {
    @Test
    func importMenuWaitsForSettingsAndDiscovery() {
        var state = BrowserWebExtensionsCardState()

        #expect(!state.canUseImportMenu(supported: true, hasObservedValue: true))

        state.completeDiscovery([])

        #expect(!state.canUseImportMenu(supported: true, hasObservedValue: false))
        #expect(!state.canUseImportMenu(supported: false, hasObservedValue: true))
        #expect(state.canUseImportMenu(supported: true, hasObservedValue: true))
    }

    @Test
    func matchingWriteFailureRollsBackAndSurfacesError() {
        let observed = [entry(id: "existing")]
        let pending = observed + [entry(id: "new")]
        var state = BrowserWebExtensionsCardState()
        state.beginWrite(entries: pending, writeID: 2)

        state.reconcileWriteResult(completedWriteID: 1, failed: true)
        #expect(state.effectiveEntries(observed: observed) == pending)
        #expect(!state.hasWriteError)

        state.reconcileWriteResult(completedWriteID: 2, failed: true)
        #expect(state.effectiveEntries(observed: observed) == observed)
        #expect(state.hasWriteError)

        let externallyUpdated = [entry(id: "external")]
        state.reconcileObservedEntries(externallyUpdated)
        #expect(!state.hasWriteError)

        state.beginWrite(entries: pending, writeID: 3)
        #expect(!state.hasWriteError)
    }

    @Test
    func observedPendingValueCompletesOptimisticWrite() {
        let observed = [entry(id: "existing")]
        let pending = observed + [entry(id: "new")]
        var state = BrowserWebExtensionsCardState()
        state.beginWrite(entries: pending, writeID: 1)

        state.reconcileObservedEntries(observed)
        #expect(state.effectiveEntries(observed: observed) == pending)

        state.reconcileObservedEntries(pending)
        #expect(state.effectiveEntries(observed: pending) == pending)
        #expect(state.pendingWriteID == nil)
    }

    private func entry(id: String) -> BrowserWebExtensionEntry {
        BrowserWebExtensionEntry(
            id: id,
            kind: .unpackedDirectory,
            path: "/Extensions/\(id)",
            enabled: true
        )
    }
}
