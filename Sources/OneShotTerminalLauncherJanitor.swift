import Foundation

/// Periodically removes sensitive launchers left behind by a prior process.
@MainActor
final class OneShotTerminalLauncherJanitor {
    private let cleanupInterval: DispatchTimeInterval
    private let pruneExpiredLaunchers: @Sendable () -> Void
    private let makeCleanupTimer: () -> DispatchSourceTimer
    private var cleanupTimer: DispatchSourceTimer?

    init(
        cleanupInterval: DispatchTimeInterval = .seconds(5 * 60),
        pruneExpiredLaunchers: @escaping @Sendable () -> Void = {
            OneShotTerminalLauncherStore().pruneExpiredSensitiveLaunchers()
        },
        makeCleanupTimer: @escaping () -> DispatchSourceTimer = {
            DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        }
    ) {
        self.cleanupInterval = cleanupInterval
        self.pruneExpiredLaunchers = pruneExpiredLaunchers
        self.makeCleanupTimer = makeCleanupTimer
    }

    func start() {
        guard cleanupTimer == nil else { return }
        pruneExpiredLaunchers()

        let timer = makeCleanupTimer()
        timer.schedule(
            deadline: .now() + cleanupInterval,
            repeating: cleanupInterval
        )
        timer.setEventHandler(handler: pruneExpiredLaunchers)
        timer.resume()
        cleanupTimer = timer
    }

    func stop() {
        guard let cleanupTimer else { return }
        self.cleanupTimer = nil
        cleanupTimer.setEventHandler {}
        cleanupTimer.cancel()
    }

    deinit {
        cleanupTimer?.setEventHandler {}
        cleanupTimer?.cancel()
    }
}
