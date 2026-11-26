import Foundation

@MainActor
final class RestoreSpawnRecorder<Value: Sendable> {
    private(set) var values: [Value] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func append(_ value: Value) {
        values.append(value)
        let ready = countWaiters.filter { values.count >= $0.count }
        countWaiters.removeAll { values.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func waitForCount(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }
}
