import Foundation

/// One bridge-confirmed React Grab state transition. JavaScript evaluation
/// only proves that a request was issued; this waiter completes from the
/// plugin's structured `stateChange` callback or a bounded timeout.
@MainActor
final class ReactGrabStateConfirmation {
    let target: Bool
    private let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init(target: Bool) {
        self.target = target
        let pair = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    func receive(_ state: Bool) {
        guard state == target else { return }
        continuation.yield(true)
        continuation.finish()
    }

    func cancel() {
        continuation.yield(false)
        continuation.finish()
    }

    func wait(timeout: Duration = .seconds(3)) async -> Bool {
        let timeoutTimer = makeTimeoutTimer(after: timeout)
        defer { timeoutTimer.invalidate() }

        let stream = stream
        let continuation = continuation
        return await withTaskCancellationHandler {
            for await confirmed in stream {
                return confirmed
            }
            return false
        } onCancel: {
            continuation.yield(false)
            continuation.finish()
        }
    }

    private func makeTimeoutTimer(after timeout: Duration) -> Timer {
        let components = timeout.components
        let interval = max(
            0,
            TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        )
        let continuation = continuation
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            continuation.yield(false)
            continuation.finish()
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
