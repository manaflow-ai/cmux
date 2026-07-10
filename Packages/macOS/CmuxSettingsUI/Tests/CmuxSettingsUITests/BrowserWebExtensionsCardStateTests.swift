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
    func emptyStateWaitsForFirstObservedValue() {
        let state = BrowserWebExtensionsCardState()

        // Before the JSON stream delivers a value, empty entries only reflect
        // the model default — not "no extensions added".
        #expect(!state.shouldShowEmptyState(entries: [], hasObservedValue: false))
        #expect(state.shouldShowEmptyState(entries: [], hasObservedValue: true))
        #expect(!state.shouldShowEmptyState(entries: [entry(id: "existing")], hasObservedValue: true))
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
        #expect(state.hasWriteError)

        state.beginWrite(entries: pending, writeID: 3)
        #expect(!state.hasWriteError)
    }


    @Test
    func successfulWriteWaitsForMatchingObservation() {
        let observed = [entry(id: "existing")]
        let pending = observed + [entry(id: "new")]
        var state = BrowserWebExtensionsCardState()
        state.beginWrite(entries: pending, writeID: 1, observationRevision: 4)

        state.reconcileWriteResult(completedWriteID: 1, failed: false)
        #expect(state.pendingWriteID == 1)
        #expect(state.effectiveEntries(observed: observed) == pending)

        state.reconcileObservedEntries(pending, observationRevision: 5)
        #expect(state.pendingWriteID == nil)
        #expect(state.effectiveEntries(observed: pending) == pending)
    }

    @Test
    func observationBeforeCompletionKeepsOptimisticValueUntilSuccess() {
        let observed = [entry(id: "existing")]
        let pending = observed + [entry(id: "new")]
        var state = BrowserWebExtensionsCardState()
        state.beginWrite(entries: pending, writeID: 1, observationRevision: 1)

        state.reconcileObservedEntries(pending, observationRevision: 2)
        #expect(state.pendingWriteID == 1)
        state.reconcileWriteResult(completedWriteID: 1, failed: false)
        #expect(state.pendingWriteID == nil)
    }

    @Test
    func staleEqualObservationCannotAcknowledgeNewestWrite() {
        let original = [entry(id: "original")]
        let newest = [entry(id: "newest")]
        var state = BrowserWebExtensionsCardState()
        state.beginWrite(entries: newest, writeID: 2, observationRevision: 10)

        state.reconcileObservedEntries(newest, observationRevision: 9)
        state.reconcileWriteResult(completedWriteID: 2, failed: true)
        #expect(state.pendingWriteID == nil)
        #expect(state.effectiveEntries(observed: original) == original)
        #expect(state.hasWriteError)
    }

    @Test
    func successfulWriteDoesNotClearNewerPendingWrite() {
        let first = [entry(id: "first")]
        let second = [entry(id: "second")]
        var state = BrowserWebExtensionsCardState()
        state.beginWrite(entries: first, writeID: 1, observationRevision: 1)
        state.beginWrite(entries: second, writeID: 2, observationRevision: 2)

        state.reconcileWriteResult(completedWriteID: 1, failed: false)
        #expect(state.pendingWriteID == 2)
        #expect(state.effectiveEntries(observed: []) == second)
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
