import Foundation

protocol UpdateOperationTimeoutCancellable: AnyObject {
    @MainActor
    func cancel()
}

protocol UpdateOperationTimeoutScheduling: AnyObject {
    @MainActor
    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any UpdateOperationTimeoutCancellable
}

final class UpdateOperationRunLoopTimeoutScheduler: UpdateOperationTimeoutScheduling {
    @MainActor
    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any UpdateOperationTimeoutCancellable {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            Task { @MainActor in
                action()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return UpdateOperationTimerToken(timer: timer)
    }
}

private final class UpdateOperationTimerToken: UpdateOperationTimeoutCancellable {
    private var timer: Timer?

    init(timer: Timer) {
        self.timer = timer
    }

    @MainActor
    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
