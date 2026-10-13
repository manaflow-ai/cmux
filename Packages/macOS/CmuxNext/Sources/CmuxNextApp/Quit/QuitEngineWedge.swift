import CmuxNextControl
import Dispatch

#if DEBUG
/// A debug seam for the quit's last step (cx-ccjnn): blocks the main thread
/// for good, as CefShutdown did on a capture mini (the main thread in a
/// Chromium mach_msg, Chromium's own shutdown watchdog never firing), so a
/// journey can prove that a quit still ends. Armed only by
/// `debug.quit {wedge_engine_stop: true}`; debug builds only.
enum QuitEngineWedge {
    @MainActor
    static func block(_ watchdog: MainThreadWatchdog?) {
        // As in a release build: the hang is reported, never asserted.
        watchdog?.endHangAssertions()
        // concurrency-allow: debug seam that blocks the main thread on purpose, as the wedged CefShutdown did
        let never = DispatchSemaphore(value: 0)
        // concurrency-allow: debug seam; nothing signals it, the process must end around it
        never.wait()
    }
}
#endif
