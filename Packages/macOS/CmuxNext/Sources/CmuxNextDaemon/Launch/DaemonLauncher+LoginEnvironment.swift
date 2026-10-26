public import CmuxNextWakeups

extension DaemonLauncher {
    /// Posts this launch's login-environment capture (`$SHELL -l -i`, 1-17 s) as an afterStartup
    /// task on the `.system` lane at ``WorkPriority/bestEffort`` (QoS `.utility`), so a launch with
    /// a remembered environment spawns no shell before startup completes; the capture refreshes the
    /// copy the next launch remembers. Chrome defers the same kind of work with
    /// `AfterStartupTaskUtils::PostTask` (chrome/browser/after_startup_task_utils.cc). A cold daemon
    /// with nothing remembered, or a new terminal before then, starts it at once at
    /// `.userInitiated` (`LoginEnvironmentCache.immediate()` and `value()`).
    ///
    /// ```swift
    /// DaemonLauncher.postLoginEnvironmentCapture(on: order.startup)
    /// ```
    public static func postLoginEnvironmentCapture(on startup: StartupScheduler) {
        postLoginEnvironmentCapture(on: startup) {
            // task-owner: one-shot fill of the process-lifetime login-env cache; ends with the capture's own timeout.
            Task(priority: .utility) { await LoginEnvironmentCache.shared.start() }
        }
    }

    /// The post of ``postLoginEnvironmentCapture(on:)`` with the capture's start injected (tests).
    static func postLoginEnvironmentCapture(on startup: StartupScheduler, start: @escaping @Sendable () -> Void) {
        startup.post(.afterStartup, "LoginEnvironment.capture", on: .lane(.system, .bestEffort), start)
    }
}
