import CmuxNextBridge
import Observation
import Testing

/// The pane a window last focused per workspace (``TabSelectionMemory/focus(_:in:)``) is keyed: a focus in one
/// workspace re-maps that workspace's sidebar row only, and focus that stays on a pane (every key typed into it)
/// re-maps nothing.
@MainActor
struct PaneFocusMemoryObservationTests {
    // onChange runs synchronously inside the change's willSet, on this test's main actor; the class only
    // carries the flag across the Sendable onChange closure.
    private nonisolated final class Flag: @unchecked Sendable { var raised = false }

    /// Whether `change` fires an observation of `read`.
    private func fires(_ read: () -> Void, after change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking { read() } onChange: { flag.raised = true }
        change()
        return flag.raised
    }

    @Test func aFocusChangeInOneWorkspaceObservesThatWorkspaceOnly() {
        let memory = TabSelectionMemory()
        memory.focus("pane-a", in: "w1")
        memory.focus("pane-x", in: "w2")
        #expect(fires({ _ = memory.focusedPane(in: "w1") }, after: { memory.focus("pane-b", in: "w1") }))
        #expect(!fires({ _ = memory.focusedPane(in: "w1") }, after: { memory.focus("pane-y", in: "w2") }))
        #expect(memory.focusedPane(in: "w1") == "pane-b")
        #expect(memory.focusedPane(in: "w2") == "pane-y")
    }

    @Test func focusThatStaysOnItsPaneChangesNothing() {
        let memory = TabSelectionMemory()
        memory.focus("pane-a", in: "w1")
        #expect(!fires({ _ = memory.focusedPane(in: "w1") }, after: { memory.focus("pane-a", in: "w1") }))
    }

    /// A relaunch seeds each workspace's saved pane, the shown workspace's own pane winning.
    @Test func aRelaunchRestoresEachWorkspacesFocusedPane() {
        let memory = TabSelectionMemory()
        memory.restoreFocus(["w1": "pane-a", "w2": "pane-x"], shown: "w1", pane: "pane-b")
        #expect(memory.focusedPane(in: "w1") == "pane-b")
        #expect(memory.focusedPane(in: "w2") == "pane-x")
        memory.focus(nil, in: "w2")
        #expect(memory.focusedPane(in: "w2") == "pane-x")
    }

    @Test func aWorkspaceNeverFocusedHasNoPane() {
        #expect(TabSelectionMemory().focusedPane(in: "w1") == nil)
    }
}
