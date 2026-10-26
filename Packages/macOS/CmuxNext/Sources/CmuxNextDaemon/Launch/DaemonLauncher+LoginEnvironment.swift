public import CmuxNextCompat
public import CmuxNextWakeups

extension DaemonLauncher {
    /// Starts this launch's login-environment capture (`$SHELL -l -i`, 1-17 s) when it is needed:
    ///
    /// - at once, at `.userInitiated`, when no copy is remembered from an earlier launch. A warm
    ///   daemon never runs `server ensure`, so without this the first terminal would wait for a
    ///   capture from zero (``LoginEnvironmentCache/startIfNothingRemembered()``);
    /// - else at `.utility` once `startup` completes, to refresh the copy the next launch
    ///   remembers, so a launch with a remembered copy spawns no shell before startup completes.
    ///
    /// Chrome defers the same kind of work with `AfterStartupTaskUtils::PostTask`
    /// (chrome/browser/after_startup_task_utils.cc). The capture is async (`ProcessRunner`), so it
    /// starts from the scheduler's completion and runs as its own task, not as a lane post that
    /// would only spawn it.
    ///
    /// ```swift
    /// DaemonLauncher.captureLoginEnvironment(after: order.startup)
    /// ```
    @MainActor
    public static func captureLoginEnvironment(after startup: StartupScheduler) {
        captureLoginEnvironment(LoginEnvironmentCache.shared, after: startup)
    }

    /// Registers this launch's login environment with the app's memory coordinator
    /// (`login-environment`), so the memory report shows it and a release drops the store's copy once
    /// the capture is held. The environment keeps the registration.
    ///
    /// ```swift
    /// DaemonLauncher.registerLoginEnvironmentMemoryConsumer(with: memoryCoordinator)
    /// ```
    ///
    /// - Parameter registry: The memory coordinator (AppServices+Memory.swift).
    @MainActor
    public static func registerLoginEnvironmentMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        LoginEnvironmentCache.shared.registerMemoryConsumer(with: registry)
    }

    /// ``captureLoginEnvironment(after:)`` on `cache` (tests).
    @MainActor
    static func captureLoginEnvironment(_ cache: LoginEnvironmentCache, after startup: StartupScheduler) {
        Self.startCaptureIfNothingRemembered(cache)
        startup.whenComplete { _ in Self.refresh(cache) }
    }

    /// Off main (this function is nonisolated, so its task is too): one store read, and the capture
    /// at `.userInitiated` only when nothing is remembered.
    private static func startCaptureIfNothingRemembered(_ cache: LoginEnvironmentCache) {
        // task-owner: one store read; a capture it starts ends with its own timeout.
        Task(priority: .userInitiated) { await cache.startIfNothingRemembered() }
    }

    /// Off main: the refresh of the copy the next launch remembers, at `.utility`.
    private static func refresh(_ cache: LoginEnvironmentCache) {
        // task-owner: one-shot refresh of the process-lifetime login-env cache; ends with the capture's own timeout.
        Task(priority: .utility) { await cache.start() }
    }
}
