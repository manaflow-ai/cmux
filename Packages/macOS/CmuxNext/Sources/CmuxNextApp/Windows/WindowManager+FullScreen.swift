import AppKit
import CmuxNextWakeups

// Windows saved in full screen enter it again after a relaunch (every app
// update relaunches), once restore finished: never from the launch snapshot,
// whose window restore adopts again and re-frames.
extension WindowManager {
    /// Longest wait for a window's full screen transition to begin.
    private static let fullScreenStartLimit: Duration = .seconds(3)
    /// Settle time after it began, so the next window's transition does not
    /// overlap it (AppKit runs one at a time).
    private static let fullScreenSettle: Duration = .milliseconds(800)

    /// Starts the next restored full screen window that is on screen. One at
    /// a time; a window clears its flag only once in full screen (or when
    /// its transition never starts), so a window still off screen keeps it
    /// and enters when presented. Tests and no-activate runs never do. After an update relaunch
    /// behind the user's app it waits until the user is in cmux (entering full screen switches Space
    /// and activates the app); the app's activation retries it (`AppDelegate`).
    func enterRestoredFullScreens() {
        guard fullScreenRestoreReady, !fullScreenRestoreRunning, ordersWindowsIn,
              services.environment.testWindow == nil, !services.environment.noActivate,
              services.environment.relaunchBehind == nil || (NSApp.isActive && !services.input.isRelaunchBehind) else { return }
        guard let controller = controllers.first(where: { $0.state.restoresFullScreen && $0.window?.isVisible == true }),
              let window = controller.window else { return }
        if window.styleMask.contains(.fullScreen) {
            controller.state.restoresFullScreen = false
            enterRestoredFullScreens()
            return
        }
        fullScreenRestoreRunning = true
        window.toggleFullScreen(nil)
        Task { @MainActor [weak self, weak controller, weak window] in
            await RestoredFullScreen.waitForStart(of: window, limit: Self.fullScreenStartLimit)
            await RestoredFullScreen.settle(Self.fullScreenSettle)
            controller?.state.restoresFullScreen = false
            guard let self else { return }
            fullScreenRestoreRunning = false
            enterRestoredFullScreens()
        }
    }
}

/// The waits of a restored window's full screen entry: events and one-shot
/// deadlines, not polls.
private enum RestoredFullScreen {
    /// Until the transition begins (AppKit puts `.fullScreen` in the style
    /// mask and posts willEnterFullScreen), or `limit` passes.
    static func waitForStart(of window: NSWindow?, limit: Duration) async {
        let began = Task { @MainActor [weak window] in
            guard let window else { return }
            let entering = NotificationCenter.default.notifications(named: NSWindow.willEnterFullScreenNotification, object: window)
            guard !window.styleMask.contains(.fullScreen) else { return }
            for await _ in entering { return }
        }
        let bound = DemandTimer(owner: "WindowManager.fullScreenStart")
        bound.schedule(after: limit) { @MainActor in began.cancel() }
        await began.value
        bound.cancel()
    }

    static func settle(_ delay: Duration) async {
        let settle = DemandTimer(owner: "WindowManager.fullScreenSettle")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            settle.schedule(after: delay) { continuation.resume() }
        }
        settle.cancel()  // keeps it alive until it fires: its deinit drops the deadline
    }
}
