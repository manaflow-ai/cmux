import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// The layout's frames and model syncs re-check the window's traffic-light avoiders once each. Every pane that moves
/// in them tells its content, which may ask the window to re-check every avoider (`WindowControlsAvoiders.refresh`):
/// batched, a frame that moves N panes re-checks each avoider once, at its end, in the same turn (RESIZE VIDEOS F1).
extension LayoutRootView {
    /// One display frame of the layout (``advanceFrameBatched(_:)``), its avoider re-checks batched.
    func advanceFrame(_ dt: Double) -> Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        // A film zoom's key turn not committed yet: this tick (the display link fired in the same run-loop pass,
        // before the commit) does nothing, so the turn commits only its model change and its grid send.
        if framesHeldPastCommit {
            MotionTrace.interval("zk.held") {}
            return true
        }
        #endif
        return MotionTrace.interval("zk.frame") { WindowControlsAvoiders.batching(in: window) { advanceFrameBatched(dt) } }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// ZOOM VARIANTS 2 (Z4 key turn < 10 ms): the window layout pass and the zoom's presentation (the covered panes'
    /// fade, the masks) run on the first frame tick after the key turn's Core Animation commit, as V0's first motion
    /// frame does, not in a tick the display link fires in the key's own run-loop pass (Chrome: input changes the model
    /// in its turn, the frame follows at the next begin-frame).
    func holdFramesPastCommit() {
        guard !framesHeldPastCommit else { return }
        framesHeldPastCommit = true
        // After Core Animation's commit (order 2,000,000) of this pass; it draws nothing itself, it lets the ticks run.
        framesHeldObserver = MainRunLoopObserver(activities: [.beforeWaiting, .exit], repeats: false, order: 2_000_001,
                                                 drawsNothingAfterCommit: true) { [weak self] _ in
            guard let self else { return }
            self.framesHeldPastCommit = false
            self.framesHeldObserver = nil
            self.driver.start()
        }
    }
    #endif

    /// A model change (``syncBatched(_:)``), its avoider re-checks batched as in a frame.
    func sync(_ snapshot: Snapshot) {
        MotionTrace.interval("zk.sync") { WindowControlsAvoiders.batching(in: window) { syncBatched(snapshot) } }
    }
}
