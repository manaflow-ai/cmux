import AppKit
import CmuxNextWakeups

// Windows saved in full screen enter it again after a relaunch (every app
// update relaunches), once restore finished: never from the launch snapshot,
// whose window restore adopts again and re-frames.
extension WindowManager {
    /// Starts the next restored full screen window that is on screen. One at
    /// a time; a window clears its flag only once in full screen (or when
    /// its transition never starts), so a window still off screen keeps it
    /// and enters when presented. Tests and no-activate runs never do. After an update relaunch
    /// behind the user's app it waits until the user is in cmux (entering full screen switches Space
    /// and activates the app); the app's activation retries it (`AppDelegate`).
    func enterRestoredFullScreens() {
        guard fullScreenRestoreReady, fullScreenRestore == nil, ordersWindowsIn,
              services.environment.testWindow == nil, !services.environment.noActivate,
              services.environment.relaunchBehind == nil || (NSApp.isActive && !services.input.isRelaunchBehind) else { return }
        guard let controller = controllers.first(where: { $0.state.restoresFullScreen && $0.window?.isVisible == true }),
              let window = controller.window else { return }
        if window.styleMask.contains(.fullScreen) {
            controller.state.restoresFullScreen = false
            enterRestoredFullScreens()
            return
        }
        window.toggleFullScreen(nil)
        fullScreenRestore = RestoredFullScreen(window: window, events: WindowEvents.of(window),
                                               deadlines: services.mainDeadlines) { [weak self, weak controller] in
            controller?.state.restoresFullScreen = false
            guard let self else { return }
            fullScreenRestore = nil
            enterRestoredFullScreens()
        }
    }
}

/// One restored window's full screen entry: the transition's start (AppKit puts `.fullScreen` in the style
/// mask and posts willEnterFullScreen), bounded by ``startLimit``, then ``settle`` so the next window's
/// transition does not overlap it (AppKit runs one at a time). Events and one deadline, not polls.
@MainActor
final class RestoredFullScreen {
    /// Longest wait for the transition to begin.
    static let startLimit: Duration = .seconds(3)
    /// Settle time after it began.
    static let settle: Duration = .milliseconds(800)

    private var began: EventSubscription?
    /// The start bound, then the settle time: one deadline, rescheduled once.
    private let deadline: MainDeadline
    private let done: @MainActor () -> Void
    private var settling = false

    /// - Parameters:
    ///   - window: The window whose transition was just asked for.
    ///   - events: The window's notices (`WindowEvents.of(window)`; tests pass one on their own center).
    ///   - deadlines: The app's one main-thread deadline scheduler.
    ///   - done: Runs once the transition began (or never did) and settled.
    init(window: NSWindow, events: WindowEvents, deadlines: MainDeadlineScheduler, done: @escaping @MainActor () -> Void) {
        self.done = done
        deadline = MainDeadline(owner: "WindowManager.fullScreenRestore", workClass: .visible, scheduler: deadlines)
        guard !window.styleMask.contains(.fullScreen) else {
            startSettling()
            return
        }
        // raw-observer-allow: the name opens a subscription on the window's one WindowEvents (recipe R-notif)
        began = events.subscribe(NSWindow.willEnterFullScreenNotification, owner: "WindowManager.fullScreenRestore") { [weak self] in
            self?.startSettling()
        }
        deadline.schedule(after: Self.startLimit) { [weak self] in self?.startSettling() }
    }

    /// The transition began, or its start bound passed: the next window waits ``settle``.
    private func startSettling() {
        guard !settling else { return }
        settling = true
        began?.cancel()
        began = nil
        deadline.schedule(after: Self.settle) { [weak self] in self?.done() }
    }
}
