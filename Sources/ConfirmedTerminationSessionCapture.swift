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
}
