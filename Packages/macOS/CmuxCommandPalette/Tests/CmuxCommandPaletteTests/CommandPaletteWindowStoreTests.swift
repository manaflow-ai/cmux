import Foundation
import Testing
@testable import CmuxCommandPalette

@MainActor
@Suite("CommandPaletteWindowStore")
struct CommandPaletteWindowStoreTests {
    @Test("register seeds baseline visibility, selection, and snapshot")
    func registerSeedsBaseline() {
        let store = CommandPaletteWindowStore()
        let id = UUID()
        store.registerWindow(id)
        #expect(store.isVisible(id) == false)
        #expect(store.selectionIndex(id) == 0)
        #expect(store.snapshot(id).mode == "commands")
        #expect(store.snapshot(id).results.isEmpty)
    }

    @Test("remove clears every per-window field")
    func removeClearsState() {
        let store = CommandPaletteWindowStore()
        let id = UUID()
        store.registerWindow(id)
        store.setVisible(true, for: id)
        store.markOpenRequested(id, now: 100)
        store.beginEscapeSuppression(id, now: 100)
        store.setSelectionIndex(3, for: id)
        store.removeWindow(id)
        #expect(store.isVisible(id) == false)
        #expect(store.isPendingOpenRaw(id) == false)
        #expect(store.selectionIndex(id) == 0)
        #expect(store.firstVisibleWindowId() == nil)
        #expect(store.firstPendingOpenWindowId() == nil)
    }

    @Test("pending-open is live within max age and pruned after")
    func pendingOpenPruning() {
        let store = CommandPaletteWindowStore()
        let id = UUID()
        store.markOpenRequested(id, now: 100)
        #expect(store.isPendingOpen(id, now: 100 + CommandPaletteWindowStore.pendingOpenMaxAge) == true)
        #expect(store.isPendingOpen(id, now: 100 + CommandPaletteWindowStore.pendingOpenMaxAge + 0.01) == false)
    }

    @Test("recentRequestAge returns age only within grace interval")
    func recentRequestAgeWithinGrace() {
        let store = CommandPaletteWindowStore()
        let id = UUID()
        store.markOpenRequested(id, now: 100)
        let age = store.recentRequestAge(id, now: 100 + CommandPaletteWindowStore.requestGraceInterval)
        #expect(age == CommandPaletteWindowStore.requestGraceInterval)
        #expect(store.recentRequestAge(id, now: 100 + CommandPaletteWindowStore.requestGraceInterval + 0.01) == nil)
    }

    @Test("setPendingOpenAge seam drives recentRequestAge")
    func setPendingOpenAgeSeam() {
        let store = CommandPaletteWindowStore()
        let id = UUID()
        store.setPendingOpenAge(id, now: 200, age: 1.0)
        #expect(store.recentRequestAge(id, now: 200) == 1.0)
        store.setPendingOpenAge(id, now: 200, age: 6.25)
        #expect(store.recentRequestAge(id, now: 200) == nil)
    }

    @Test("escape suppression consumed only within suppression window")
    func escapeSuppression() {
        let store = CommandPaletteWindowStore()
        let id = UUID()
        store.beginEscapeSuppression(id, now: 100)
        #expect(store.shouldConsumeSuppressedEscape(id, now: 100 + CommandPaletteWindowStore.escapeSuppressionInterval) == true)
        store.beginEscapeSuppression(id, now: 100)
        // Past the window: not consumed and cleaned up.
        #expect(store.shouldConsumeSuppressedEscape(id, now: 100 + CommandPaletteWindowStore.escapeSuppressionInterval + 0.01) == false)
        #expect(store.shouldConsumeSuppressedEscape(id, now: 100) == false)
    }

    @Test("repeated false visibility retains an in-flight pending open")
    func falseVisibilityRetainsPending() {
        let store = CommandPaletteWindowStore()
        let id = UUID()
        store.markOpenRequested(id, now: 100)
        let update = store.setVisible(false, for: id)
        #expect(update.wasVisible == false)
        #expect(update.retainedPending == true)
        #expect(store.isPendingOpenRaw(id) == true)
    }

    @Test("opening then closing clears pending open")
    func openCloseClearsPending() {
        let store = CommandPaletteWindowStore()
        let id = UUID()
        store.markOpenRequested(id, now: 100)
        let open = store.setVisible(true, for: id)
        #expect(open.wasVisible == false)
        #expect(store.isPendingOpenRaw(id) == false)
        let close = store.setVisible(false, for: id)
        #expect(close.wasVisible == true)
        #expect(store.isVisible(id) == false)
    }

    @Test("selection index is clamped to zero")
    func selectionClamped() {
        let store = CommandPaletteWindowStore()
        let id = UUID()
        store.setSelectionIndex(-5, for: id)
        #expect(store.selectionIndex(id) == 0)
        store.setSelectionIndex(7, for: id)
        #expect(store.selectionIndex(id) == 7)
    }

    @Test("prune reports missing-timestamp and stale outcomes")
    func pruneOutcomes() {
        let store = CommandPaletteWindowStore()
        let stale = UUID()
        store.markOpenRequested(stale, now: 0)
        let pruned = store.pruneExpiredPendingOpenStates(now: CommandPaletteWindowStore.pendingOpenMaxAge + 1)
        #expect(pruned.count == 1)
        if case .stale(let windowId, _) = pruned[0] {
            #expect(windowId == stale)
        } else {
            Issue.record("expected stale outcome")
        }
    }
}
