internal import Foundation

/// Process-local fanout for disruptive shared-ControlMaster resets.
final class NativeSSHControlMasterResetEventHub: @unchecked Sendable {
    // lint:allow lock - subscription and synchronous event snapshots are tiny.
    private let lock = NSLock()
    private var observers: [
        UUID: (
            controlPath: String,
            handler: @Sendable () -> Void
        )
    ] = [:]

    func observe(
        controlPath: String,
        handler: @escaping @Sendable () -> Void
    ) -> NativeSSHControlMasterResetObservation {
        let id = UUID()
        lock.withLock {
            observers[id] = (controlPath: controlPath, handler: handler)
        }
        return NativeSSHControlMasterResetObservation { [weak self] in
            self?.removeObserver(id)
        }
    }

    func emit(controlPath: String) {
        let handlers = lock.withLock {
            observers.values.compactMap { observer in
                observer.controlPath == controlPath ? observer.handler : nil
            }
        }
        for handler in handlers {
            handler()
        }
    }

    private func removeObserver(_ id: UUID) {
        lock.withLock {
            _ = observers.removeValue(forKey: id)
        }
    }
}

/// Lifetime token for one ControlMaster-reset observer.
final class NativeSSHControlMasterResetObservation: @unchecked Sendable {
    // lint:allow lock - cancellation exchanges one closure exactly once.
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    deinit {
        let cancellation = lock.withLock {
            let value = self.cancellation
            self.cancellation = nil
            return value
        }
        cancellation?()
    }
}
