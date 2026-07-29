internal import Foundation

/// Sendable ownership boundary for Dispatch's thread-safe timer source.
final class CommandTimer: @unchecked Sendable {
    private let source: any DispatchSourceTimer

    init(queue: DispatchQueue) {
        source = DispatchSource.makeTimerSource(queue: queue)
    }

    func schedule(deadline: DispatchTime) {
        source.schedule(deadline: deadline)
    }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setEventHandler(handler: handler)
    }

    func cancel() {
        source.cancel()
    }

    func resume() {
        source.resume()
    }
}
