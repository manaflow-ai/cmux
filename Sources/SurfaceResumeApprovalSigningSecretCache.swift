import Foundation

/// Resolves the surface-resume signing secret once without making main-thread
/// callers wait for Keychain or filesystem I/O.
///
/// A `nil` result is cached deliberately. Without an explicit ready state,
/// every autosave tick would retry `SecItemCopyMatching` for every terminal
/// panel when Keychain access fails.
final class SurfaceResumeApprovalSigningSecretCache: @unchecked Sendable {
    private enum State {
        case unresolved
        case loading
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
        let decision: Decision = lock.withLock {
            switch state {
            case .unresolved:
                state = .loading
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

    @discardableResult
    private func resolve() -> Data? {
        let value = loader()
        lock.withLock {
            state = .ready(value)
        }
        return value
    }

    private enum Decision {
        case `return`(Data?)
        case schedule
        case load
    }
}
