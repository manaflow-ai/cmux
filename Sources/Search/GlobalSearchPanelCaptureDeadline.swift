import Foundation

/// Owns the shared deadline for one bounded global-search content refresh.
@MainActor
final class GlobalSearchPanelCaptureDeadline {
    typealias ExpirationHandler = @MainActor () -> Void

    private(set) var hasExpired = false
    private var isCancelled = false
    private var expirationHandlers: [UUID: ExpirationHandler] = [:]
    private let timer: DispatchSourceTimer

    init(milliseconds: Int) {
        timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(max(0, milliseconds)),
            leeway: .milliseconds(10)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.expire()
            }
        }
        timer.resume()
    }

    func addExpirationHandler(
        id: UUID,
        handler: @escaping ExpirationHandler
    ) -> Bool {
        guard !hasExpired, !isCancelled else { return false }
        expirationHandlers[id] = handler
        return true
    }

    func removeExpirationHandler(id: UUID) {
        expirationHandlers[id] = nil
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        expirationHandlers.removeAll()
        timer.setEventHandler {}
        timer.cancel()
    }

    private func expire() {
        guard !hasExpired, !isCancelled else { return }
        hasExpired = true
        let handlers = Array(expirationHandlers.values)
        expirationHandlers.removeAll()
        timer.setEventHandler {}
        timer.cancel()
        isCancelled = true
        for handler in handlers {
            handler()
        }
    }
}
