import CmuxNextDesign
import CmuxNextWakeups

/// Hidden screens mounted at idle (``LayoutRootView/hiddenScreenQueue``): the frame that shows a workspace mounts the
/// screen it shows, and each other screen mounts later as one background task, so a launch or a workspace switch pays
/// for the visible screen only and a later first switch to a screen finds it made.
extension LayoutRootView {
    /// Mounts the next waiting screen as background work, then the one after it, until none waits. It waits for the
    /// launch's first pane content (`LaunchReveal` `.pane`) and the frame after it, runs only while the layout is live
    /// (shown, not parked) and still (``whenStill(_:on:_:)``: never in a motion's frames), and stops when it is not;
    /// the next show (`setLive`) or sync asks again.
    func mountDeferredScreensWhenIdle() {
        guard let queue = hiddenScreenQueue, isLive, !deferredScreens.isEmpty, !deferredMountQueued else { return }
        deferredMountQueued = true
        LaunchReveal.shared.whenReady(.pane) { [weak self] in
            AfterFrameCommit().run { [weak self] in
                self?.whenStill("layout.hiddenScreens", on: queue) { [weak self] in
                    guard let self else { return }
                    deferredMountQueued = false
                    guard isLive, mountDeferredScreen() else { return }
                    mountDeferredScreensWhenIdle()
                }
            }
        }
    }
}
