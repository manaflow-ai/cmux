public import CmuxNextWakeups

/// A quit's hold on the launch (p08-startup task 105), the steps the app's `QuitCoordinator` runs. While the quit
/// decides, startup does not complete; a decided quit ends the launch's scheduler (``StartupScheduler/beginQuit()``:
/// no afterStartup task runs during shutdown, as Chrome's `AfterStartupTaskUtils` drops them once the browser shuts
/// down); a cancelled one releases its hold with `quitCancelled`, so the launch completes again. With no launch
/// scheduler (tests, a launch with none) each step does nothing.
@MainActor
public final class QuitLaunchHold {
    private let startup: StartupScheduler?
    private var ref: StartupInProgressRef?

    /// - Parameter startup: The launch's scheduler (`AppServices.launchStartup`).
    public init(startup: StartupScheduler?) {
        self.startup = startup
    }

    /// Whether the quit holds startup now.
    public var isHolding: Bool { ref.map { !$0.isReleased } ?? false }

    /// The quit decides (`applicationShouldTerminate`): startup does not complete meanwhile. After completion
    /// the ref holds nothing.
    public func deciding() {
        guard ref == nil else { return }
        ref = startup?.hold("Quit.deciding")
    }

    /// The quit is decided: nothing held for after startup runs now, and startup never completes.
    public func decided() {
        startup?.beginQuit()
        ref = nil
    }

    /// The quit was cancelled (an unsaved document kept, the dialog's Cancel): the app stays.
    public func cancelled() {
        ref?.release(.quitCancelled)
        ref = nil
    }
}
