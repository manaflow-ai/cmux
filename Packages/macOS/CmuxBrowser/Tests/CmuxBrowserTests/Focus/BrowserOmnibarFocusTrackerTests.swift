import Foundation
import Testing

@testable import CmuxBrowser

@MainActor
@Suite("BrowserOmnibarFocusTracker")
struct BrowserOmnibarFocusTrackerTests {
    /// Builds a tracker plus an immediate (zero-delay) repeat coordinator whose
    /// selection-move sink records dispatched moves, so a test can observe that
    /// a focus change stops an in-flight repeat.
    private func makeTracker() -> (BrowserOmnibarFocusTracker, @MainActor () -> Int) {
        let dispatched = Box(0)
        let coordinator = BrowserOmnibarSelectionRepeatCoordinator(
            selectionMove: { _, _ in dispatched.value += 1 },
            sleep: { _ in }
        )
        let tracker = BrowserOmnibarFocusTracker(selectionRepeat: coordinator)
        return (tracker, { dispatched.value })
    }

    @Test("setFocused records the panel and stops the repeat")
    func setFocusedStopsRepeat() {
        let (tracker, _) = makeTracker()
        let panel = UUID()
        tracker.selectionRepeat.startRepeatIfNeeded(panelID: panel, keyCode: 7, delta: 1)
        #expect(tracker.selectionRepeat.repeatingPanelID == panel)

        tracker.setFocused(panelId: panel)
        #expect(tracker.focusedPanelId == panel)
        #expect(tracker.selectionRepeat.repeatingPanelID == nil)
    }

    @Test("markFocused records the panel without stopping the repeat")
    func markFocusedLeavesRepeat() {
        let (tracker, _) = makeTracker()
        let panel = UUID()
        tracker.selectionRepeat.startRepeatIfNeeded(panelID: panel, keyCode: 7, delta: 1)

        tracker.markFocused(panelId: panel)
        #expect(tracker.focusedPanelId == panel)
        #expect(tracker.selectionRepeat.repeatingPanelID == panel)
    }

    @Test("clearFocus(ifTrackedPanelId:) clears only on a match")
    func guardedClearMatchesPanel() {
        let (tracker, _) = makeTracker()
        let tracked = UUID()
        tracker.markFocused(panelId: tracked)
        tracker.selectionRepeat.startRepeatIfNeeded(panelID: tracked, keyCode: 7, delta: 1)

        #expect(tracker.clearFocus(ifTrackedPanelId: UUID()) == false)
        #expect(tracker.focusedPanelId == tracked)
        #expect(tracker.selectionRepeat.repeatingPanelID == tracked)

        #expect(tracker.clearFocus(ifTrackedPanelId: tracked) == true)
        #expect(tracker.focusedPanelId == nil)
        #expect(tracker.selectionRepeat.repeatingPanelID == nil)
    }

    @Test("clearFocus() clears unconditionally and stops the repeat")
    func unconditionalClear() {
        let (tracker, _) = makeTracker()
        let tracked = UUID()
        tracker.markFocused(panelId: tracked)
        tracker.selectionRepeat.startRepeatIfNeeded(panelID: tracked, keyCode: 7, delta: 1)

        tracker.clearFocus()
        #expect(tracker.focusedPanelId == nil)
        #expect(tracker.selectionRepeat.repeatingPanelID == nil)
    }
}

@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
