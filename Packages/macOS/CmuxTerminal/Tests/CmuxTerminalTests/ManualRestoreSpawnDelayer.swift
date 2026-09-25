import Foundation
@testable import CmuxTerminal

@MainActor
final class ManualRestoreSpawnDelayer: TerminalSurfaceRestoreSpawnDelaying {
    private var delayCount = 0
    private var delayOperations: [@MainActor () -> Void] = []
    private var delayOperationHead = 0
    private var countContinuations: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func scheduleDelay(
        for duration: Duration,
        operation: @escaping @MainActor () -> Void
    ) -> any TerminalSurfaceRestoreSpawnDelayCancelling {
        _ = duration
        delayCount += 1
        let count = delayCount
        for waiter in countContinuations.removeValue(forKey: count) ?? [] {
            waiter.resume()
        }
        delayOperations.append(operation)
        return ManualRestoreSpawnDelay()
    }

    func waitForDelayCount(_ count: Int) async {
        guard delayCount < count else { return }
        await withCheckedContinuation { continuation in
            countContinuations[count, default: []].append(continuation)
        }
    }

    func releaseNextDelay() {
        guard delayOperationHead < delayOperations.count else { return }
        let operation = delayOperations[delayOperationHead]
        delayOperationHead += 1
        operation()
    }
}
