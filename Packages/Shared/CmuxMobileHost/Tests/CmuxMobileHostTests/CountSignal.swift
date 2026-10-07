import Foundation

/// A counter tests wait on; waits are cancellable (they iterate an
/// AsyncStream), so `within` can time them out.
actor CountSignal {
    private(set) var value = 0
    private var observers: [UUID: AsyncStream<Int>.Continuation] = [:]

    func increment() {
        value += 1
        for observer in observers.values { observer.yield(value) }
    }

    func wait(atLeast target: Int) async {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(value)
        for await current in stream where current >= target { break }
        observers[id] = nil
    }
}
