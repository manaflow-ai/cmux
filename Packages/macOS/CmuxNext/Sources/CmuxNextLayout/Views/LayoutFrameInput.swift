import AppKit

/// The input of one display frame (FRAME OWNER REFACTOR S2), applied first in the
/// window's frame tick, before its springs step: each screen's divider, column-edge or row-edge drag writes its newest
/// pointer once (`DividerDrag.applyWaiting`), and the model syncs in the same turn (no observation hop). The
/// presentation and the overlay sync that sync asks for wait for the frame's one pass
/// (`LayoutViewContext.holdsPresentations`): after the springs stepped, a screen no spring presented presents once
/// (``presentWaiting()``), and the frame syncs the overlay once (one page geometry post). So N drag events in one
/// refresh cost one model write, one layout pass and one commit, in the frame's own transaction. Chrome aligns input
/// to the begin-frame the same way: one input batch per frame.
@MainActor
struct LayoutFrameInput {
    let root: LayoutRootView

    /// Whether a drag keeps the frame ticks (`ScreenContentView.panTickTail` frames after its last event, counted
    /// down here once per frame), so the display link is not made again for each event of a slow drag.
    func keepsTicking() -> Bool { // perf-hot: 4ms motion-frame
        var ticking = false
        for view in root.screenViews.values {
            guard let left = view.activeDrag?.ticksLeft, left > 0 else { continue }
            view.activeDrag?.ticksLeft = left - 1
            ticking = true
        }
        return ticking
    }

    /// Writes and syncs the drags that wait for this frame, their passes held for the frame's one pass.
    func apply() { // perf-hot: 4ms motion-frame
        guard root.screenViews.values.contains(where: { $0.activeDrag?.waiting == true }) else { return }
        root.context.holdsPresentations = true
        defer { root.context.holdsPresentations = false }
        for view in root.screenViews.values where view.activeDrag?.waiting == true { DividerDrag(screen: view).applyWaiting() }
        root.syncWithModel()
    }

    /// The pass a screen's presentation waited for in the frame's input, for each screen whose springs did not
    /// present it this frame (a drag moves no spring), before the frame syncs its overlay.
    func presentWaiting() { // perf-hot: 4ms motion-frame
        for view in root.screenViews.values where view.frameInput.presentationWaiting { view.applyPresentation() }
    }
}
