import Foundation

@MainActor
final class ConfirmedTerminationSessionCapture {
    typealias Capture = @MainActor () async -> ProcessDetectedResumeIndexes?

    private let watchdog: TerminationWatchdog

    init(watchdog: TerminationWatchdog) {
        self.watchdog = watchdog
    }

    func prepare(persistCoreSnapshot: @MainActor () -> Void) {
        persistCoreSnapshot()
        watchdog.arm()
    }

    func capture(using operation: Capture) async -> ProcessDetectedResumeIndexes? {
        await operation()
    }

    func captureBeforeTeardown(
        using operation: Capture,
        beginTeardown: @MainActor () -> Void
    ) async {
        _ = await capture(using: operation)
        guard !Task.isCancelled else { return }
        // The operation's owner retains the captured authority for the
        // will-terminate save. Begin teardown immediately so a second full
        // snapshot cannot consume the remote-cleanup deadline.
        beginTeardown()
    }
}
