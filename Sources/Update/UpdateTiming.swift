import Foundation

enum UpdateTiming {
    static let minimumCheckDisplayDuration: TimeInterval = 2.0
    static let noUpdateDisplayDuration: TimeInterval = 5.0
    static let updaterReadyTimeoutDuration: TimeInterval = 30.0
    static let checkingTimeoutDuration: TimeInterval = 90.0
    static let downloadingInactivityTimeoutDuration: TimeInterval = 120.0
    static let preparingTimeoutDuration: TimeInterval = 300.0
}

protocol UpdateScheduledAction: AnyObject {
    func cancel()
}

protocol UpdateOperationScheduling: AnyObject {
    @discardableResult
    func schedule(after interval: TimeInterval, _ action: @escaping () -> Void) -> UpdateScheduledAction
}

/// Single scheduler boundary for update UI deadlines. Tests swap this for a virtual
/// scheduler so retry and timeout behavior is deterministic without run-loop sleeps.
final class DispatchUpdateOperationScheduler: UpdateOperationScheduling {
    static let shared = DispatchUpdateOperationScheduler()

    private init() {}

    @discardableResult
    func schedule(after interval: TimeInterval, _ action: @escaping () -> Void) -> UpdateScheduledAction {
        let token = DispatchUpdateScheduledAction()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval)
        source.setEventHandler { [weak token] in
            guard let token else { return }
            guard token.markFired() else { return }
            action()
        }
        token.install(source)
        source.resume()
        return token
    }
}

private final class DispatchUpdateScheduledAction: UpdateScheduledAction {
    private var source: DispatchSourceTimer?
    private var cancelled = false

    deinit {
        cancel()
    }

    func install(_ source: DispatchSourceTimer) {
        guard self.source == nil else { return }
        self.source = source
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        source?.setEventHandler {}
        source?.cancel()
        source = nil
    }

    func markFired() -> Bool {
        guard !cancelled else { return false }
        cancelled = true
        source = nil
        return true
    }
}
