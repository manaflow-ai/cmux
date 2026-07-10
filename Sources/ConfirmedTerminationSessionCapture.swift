import Foundation

@MainActor
final class ConfirmedTerminationSessionCapture {
    typealias Capture = @MainActor () async -> ProcessDetectedResumeIndexes?
    typealias Completion = @MainActor (ProcessDetectedResumeIndexes?) -> Void

    private let watchdog: TerminationWatchdog

    init(watchdog: TerminationWatchdog) {
        self.watchdog = watchdog
    }

    func start(
        persistCoreSnapshot: @escaping @MainActor () -> Void,
        capture: @escaping Capture,
        completion: @escaping Completion
    ) -> Task<Void, Never> {
        persistCoreSnapshot()
        watchdog.arm()
        return Task { @MainActor in
            let resumeIndexes = await capture()
            guard !Task.isCancelled else { return }
            completion(resumeIndexes)
        }
    }
}
