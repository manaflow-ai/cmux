import QuartzCore

/// Where a view's infinite Core Animation loops live: each runs only while a person can see it,
/// and its make returns nil while loops are off (Energy Saver, Reduce Motion, the category
/// switch), leaving the layer still (plans/cmux-next/chrome-parity/p14-energy.md, tasks 056 and
/// 115). The Mac app's host is CmuxNextDesign's `LoopVisibility`, which follows the view's window
/// (occlusion, miniaturize, app hide); a Shared view that cannot see its window (CmuxHomeRender,
/// CmuxMessagesLab) is handed one. It lives here, below both, so one protocol serves both sides.
///
/// A loop's phase: one that leaves `beginTime` at 0 begins where the host's shared clock puts it,
/// so loops that start apart run in step. One that sets `beginTime` (layer time) keeps it, so a
/// caret's solid hold before its blink, or typing dots counted from their row's insert, keep their
/// timing; made again after a show, such a loop sits where it would be had it run all along.
@MainActor public protocol LoopHost: AnyObject {
    /// Runs `make`'s loop on `layer` under `key` whenever the host is visible, replacing any loop
    /// attached there before. `make` runs each time the loop starts, so it follows the motion
    /// settings of that moment.
    func attach(_ layer: CALayer, key: String, make: @escaping @MainActor () -> CAAnimation?)
    /// Takes the loop under `key` off `layer` for good.
    func detach(_ layer: CALayer, key: String)
    /// Takes every attached loop off.
    func detachAll()
}
