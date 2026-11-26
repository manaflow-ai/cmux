import AppKit
import CmuxNextDesign

/// The layout's frames and model syncs re-check the window's traffic-light avoiders once each. Every pane that moves
/// in them tells its content, which may ask the window to re-check every avoider (`WindowControlsAvoiders.refresh`):
/// batched, a frame that moves N panes re-checks each avoider once, at its end, in the same turn (RESIZE VIDEOS F1).
extension LayoutRootView {
    /// Whether the first divider drag event of a display frame lays the layout out in its own turn
    /// (``applyInputAtEvent()``). Before, every event only kept its pointer for the window's next display-link tick,
    /// which wrote the newest one: the panes, and the Chromium pages in them, took the new size up to a refresh after
    /// the pointer moved (8.3 ms at 120 Hz), and a page whose size came after its compositor's begin-frame waited one
    /// more refresh for its frame. `CMUX_NEXT_DIVIDER_INPUT_AT_EVENT=1` turns it on (a bench arm of the page-sync levers
    /// until measured); a `CMUX_NEXT_` launch knob, so the launch strip keeps it (`LaunchIdentity.inheritedKeys`).
    nonisolated static let inputLandsAtEvent = ProcessInfo.processInfo.environment["CMUX_NEXT_DIVIDER_INPUT_AT_EVENT"] == "1"

    /// One display frame of the layout (``advanceFrameBatched(_:)``), its avoider re-checks batched. A frame that writes
    /// a divider drag's newest pointer is that drag's step (`ResizeStepTimes`): this tick, then the layout and commit of
    /// its turn.
    func advanceFrame(_ dt: Double) -> Bool {
        // A new display frame: the next drag event may land at once again (``applyInputAtEvent()``).
        context.inputLandedSinceTick = false
        let step = ResizeStepTimes.beginStep(.divider, if: screenViews.values.contains { $0.activeDrag?.waiting == true })
        defer { ResizeStepTimes.recordLive("tick", since: step) }
        return WindowControlsAvoiders.batching(in: window) { advanceFrameBatched(dt) }
    }

    /// A divider drag's event lays the layout out in its own turn (``inputLandsAtEvent``), as the frame
    /// tick's input would (`LayoutFrameInput`: the drag's newest pointer written once, then one presentation and one
    /// overlay sync): the panes and their pages get the new size when the pointer moves, not at the next display-link
    /// tick up to a refresh later. At most one event per display frame lands this way (the tick clears the mark); the
    /// rest wait for the tick as before, so a burst of events still costs at most two layout passes a frame. Not while a
    /// spring moves anything (its frame's one pass owns the presentation) or under Reduce Motion.
    /// - Returns: Whether the event's input landed now.
    func applyInputAtEvent() -> Bool { // perf-hot: 4ms motion-frame (each divider drag event that lands)
        guard context.inputLandsAtEvent, isLive, window != nil, driver.isAttached, !context.reduceMotion,
              !context.inputLandedSinceTick,
              screenViews.values.contains(where: { $0.activeDrag?.waiting == true }),
              !screenViews.values.contains(where: \.hasMotion) else { return false }
        context.inputLandedSinceTick = true
        let step = ResizeStepTimes.beginStep(.divider)
        defer { ResizeStepTimes.recordLive("tick", since: step, detail: " at_event=1") }
        WindowControlsAvoiders.batching(in: window) {
            // The tick's own order with nothing springing (``advanceFrameBatched(_:)``): input, presentation, visibility,
            // the motion flag as a gesture sets it, one overlay sync.
            let input = LayoutFrameInput(root: self)
            input.apply()
            _ = input.presentWaiting()
            updateVisibility()
            let gesturing = screenViews.values.contains(where: \.userMotionActive)
            if gesturing { setLayoutInMotion(true) }
            flushOverlaySync()
            if !gesturing { setLayoutInMotion(false) }
            onFramePlaced?()
        }
        return true
    }

    /// A model change (``syncBatched(_:)``), its avoider re-checks batched as in a frame. A probe reads its time.
    func sync(_ snapshot: Snapshot) {
        WindowControlsAvoiders.batching(in: window) { MotionTrace.measure("layout.sync") { syncBatched(snapshot) } }
    }
}
