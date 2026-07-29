internal import Foundation

/// Sendable ownership boundary for a nonblocking child-exit dispatch source.
final class CommandProcessExitSource: @unchecked Sendable {
    private let source: any DispatchSourceProcess

    init(processIdentifier: pid_t, queue: DispatchQueue) {
        source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: queue
        )
    }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setEventHandler(handler: handler)
    }

    func cancel() {
        source.cancel()
    }

    func cancelBeforeActivation() {
        source.resume()
        source.cancel()
    }

    func resume() {
        source.resume()
    }
}
