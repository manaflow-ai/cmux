import Foundation

actor LifecycleSettingsMutationSleeper {
    private let firstGate: LifecycleSyncGate
    private var invocationCount = 0
    private var firstSleepCancelled = false

    init(firstGate: LifecycleSyncGate) {
        self.firstGate = firstGate
    }

    func sleep(for duration: Duration) async throws {
        invocationCount += 1
        if invocationCount == 1 {
            await firstGate.pause()
            firstSleepCancelled = Task.isCancelled
            return
        }
        try await ContinuousClock().sleep(for: duration)
    }

    var didCancelFirstSleep: Bool { firstSleepCancelled }
}
