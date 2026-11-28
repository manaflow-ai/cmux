import AppKit
import CmuxNextDesign

/// The layout's frames and model syncs re-check the window's traffic-light avoiders once each. Every pane that moves
/// in them tells its content, which may ask the window to re-check every avoider (`WindowControlsAvoiders.refresh`):
/// batched, a frame that moves N panes re-checks each avoider once, at its end, in the same turn (RESIZE VIDEOS F1).
extension LayoutRootView {
    /// One display frame of the layout (``advanceFrameBatched(_:)``), its avoider re-checks batched. A divider drag's
    /// frame with a pointer waiting is a live resize step: it starts here, before its layout (``ResizeStepStart``).
    func advanceFrame(_ dt: Double) -> Bool {
        ResizeStepStart.begin(if: screenViews.values.contains { $0.activeDrag?.waiting == true })
        return WindowControlsAvoiders.batching(in: window) { advanceFrameBatched(dt) }
    }

    /// A model change (``syncBatched(_:)``), its avoider re-checks batched as in a frame. A probe reads its time.
    func sync(_ snapshot: Snapshot) {
        WindowControlsAvoiders.batching(in: window) { MotionTrace.measure("layout.sync") { syncBatched(snapshot) } }
    }
}
