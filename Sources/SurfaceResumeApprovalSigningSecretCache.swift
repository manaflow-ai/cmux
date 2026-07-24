import Foundation

/// Resolves the surface-resume signing secret once without making main-thread
/// callers wait for Keychain or filesystem I/O.
///
/// A `nil` result is cached deliberately. Without an explicit ready state,
/// every autosave tick would retry `SecItemCopyMatching` for every terminal
/// panel when Keychain access fails.
final class SurfaceResumeApprovalSigningSecretCache: @unchecked Sendable {
    private typealias Completion = @Sendable (Data?) -> Void

    private enum State {
        case unresolved
        case loading([Completion])
        case ready(Data?)
    }

    private let lock = NSLock()
    private let loader: @Sendable () -> Data?
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    private var state: State = .unresolved

    init(
        loader: @escaping @Sendable () -> Data?,
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) {
        self.loader = loader
        self.schedule = schedule
    }

    /// Returns the cached secret or starts its one-time resolution.
    ///
    /// Main-thread callers always return immediately. A background caller may
    /// perform the first resolution synchronously; callers arriving while that
    /// resolution is in flight observe `nil` until it completes.
    func value(isMainThread: Bool) -> Data? {
        let decision: ValueDecision = lock.withLock {
            switch state {
            case .unresolved:
                state = .loading([])
                return isMainThread ? .schedule : .load
            case .loading:
                return .return(nil)
            case let .ready(value):
                return .return(value)
            }
        }

        switch decision {
        case let .return(value):
            return value
        case .schedule:
            schedule { [weak self] in
                self?.resolve()
            }
            return nil
        case .load:
            return resolve()
        }
    }

    var isReady: Bool {
        lock.withLock {
            guard case .ready = state else { return false }
            return true
        }
    }

    /// Resolves the secret if needed and calls `completion` exactly once after
    /// the result (including a cached `nil`) becomes authoritative.
    func preload(completion: @escaping @Sendable (Data?) -> Void) {
        let decision: PreloadDecision = lock.withLock {
            switch state {
            case .unresolved:
                state = .loading([completion])
                return .schedule
            case let .loading(completions):
                state = .loading(completions + [completion])
                return .none
            case let .ready(value):
                return .complete(completion, value)
            }
        }

        switch decision {
        case .schedule:
            schedule { [weak self] in
                self?.resolve()
            }
        case let .complete(completion, value):
            completion(value)
        case .none:
            break
        }
    }

    @discardableResult
    private func resolve() -> Data? {
        let value = loader()
        let completions: [Completion] = lock.withLock {
            let completions: [Completion]
            if case let .loading(pending) = state {
                completions = pending
            } else {
                completions = []
            }
            state = .ready(value)
            return completions
        }
        completions.forEach { $0(value) }
        return value
    }

    private enum ValueDecision {
        case `return`(Data?)
        case schedule
        case load
    }

    private enum PreloadDecision {
        case schedule
        case none
        case complete(Completion, Data?)
    }
}
