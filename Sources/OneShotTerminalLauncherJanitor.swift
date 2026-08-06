import Foundation

/// Periodically removes sensitive launchers left behind by a prior process.
actor OneShotTerminalLauncherJanitor {
    static let shared = OneShotTerminalLauncherJanitor()

    private var cleanupTimer: DispatchSourceTimer?

    func start() {
        guard cleanupTimer == nil else { return }
        OneShotTerminalLauncherStore().pruneExpiredSensitiveLaunchers()

        let timer = DispatchSource.makeTimerSource(
            queue: .global(qos: .utility)
        )
        timer.schedule(
            deadline: .now() + .seconds(5 * 60),
            repeating: .seconds(5 * 60)
        )
        timer.setEventHandler {
            OneShotTerminalLauncherStore().pruneExpiredSensitiveLaunchers()
        }
        timer.resume()
        cleanupTimer = timer
    }
}
