import AppKit

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
    /// and enters when presented. Tests and no-activate runs never do.
    func enterRestoredFullScreens() {
        guard fullScreenRestoreReady, !fullScreenRestoreRunning, ordersWindowsIn,
              services.environment.testWindow == nil, !services.environment.noActivate else { return }
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
            let clock = ContinuousClock()
            let deadline = clock.now + Self.fullScreenStartLimit
            while let window, !window.styleMask.contains(.fullScreen), clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: Self.fullScreenSettle)
            controller?.state.restoresFullScreen = false
            guard let self else { return }
            fullScreenRestoreRunning = false
            enterRestoredFullScreens()
        }
    }
}
