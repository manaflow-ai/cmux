internal import Dispatch
internal import Foundation

/// Arms NOTE_EXIT before validating the exact public-kernel start tuple.
///
/// The daemon separately validates the same tuple during activation. Together
/// those checks close PID-reuse and exit-between-check-and-activation races.
/// The private serial queue protects registrations and owns process-source callbacks.
final class BackendOnlyRendererWorkerMonitor: @unchecked Sendable {
    private typealias Registration = BackendOnlyRendererWorkerRegistration
    private let queue = DispatchQueue(
        label: "com.cmux.backend-only.renderer-worker-exit",
        qos: .userInitiated
    )
    private let queueKey = DispatchSpecificKey<Void>()
    private var registrations: [BackendOnlyRendererWorkerIdentity: Registration] = [:]

    init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    func watch(
        _ identity: BackendOnlyRendererWorkerIdentity,
        onExit: @escaping @Sendable (BackendOnlyRendererWorkerIdentity) -> Void
    ) -> BackendOnlyRendererWorkerWatchResult {
        let fence = isolated {
            if let existing = registrations[identity] {
                return existing.fence
            }
            let fence = BackendOnlyRendererWorkerExitFence()
            let source = DispatchSource.makeProcessSource(
                identifier: identity.processID,
                eventMask: .exit,
                queue: queue
            )
            registrations[identity] = Registration(
                source: source,
                fence: fence,
                onExit: onExit
            )
            source.setEventHandler { [weak self] in
                self?.processExitedIsolated(identity)
            }
            source.activate()
            return fence
        }

        switch backendOnlyCurrentProcessInstanceToken(processID: identity.processID) {
        case let .exact(token) where token == identity.processInstanceToken:
            return fence.hasExited ? .alreadyExited : .watching(fence)
        case .exact, .missing:
            cancel(identity)
            return .alreadyExited
        case .unverifiable:
            cancel(identity)
            return .unverifiable
        }
    }

    func cancel(_ identity: BackendOnlyRendererWorkerIdentity) {
        let registration = isolated {
            registrations.removeValue(forKey: identity)
        }
        registration?.source.cancel()
    }

    private func processExitedIsolated(_ identity: BackendOnlyRendererWorkerIdentity) {
        let registration = registrations.removeValue(forKey: identity)
        guard let registration else { return }
        registration.fence.finish()
        registration.source.cancel()
        registration.onExit(identity)
    }

    private func isolated<Result>(_ operation: () -> Result) -> Result {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return operation()
        }
        return queue.sync(execute: operation)
    }

    deinit {
        let registrations = isolated {
            let values = Array(registrations.values)
            self.registrations.removeAll()
            return values
        }
        for registration in registrations {
            registration.source.cancel()
        }
    }
}
