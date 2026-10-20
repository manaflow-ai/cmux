public import CmuxAuthRuntime

/// Owns the Cloud resources of one auth session, independently of the signed-in UI flag.
@MainActor
package final class CloudSessionLifecycle {
    package enum Retirement: Sendable, Equatable { case session, quit }
    private let current: @MainActor @Sendable (AuthenticatedSessionIdentity) -> Bool
    private let start: @MainActor @Sendable (AuthenticatedSessionIdentity) async -> Void
    private let retire: @MainActor @Sendable (Retirement) async -> Void
    private var identity: AuthenticatedSessionIdentity?
    private var signedIn: Bool?
    private var suspended = false
    private var stopped = false

    package init(current: @escaping @MainActor @Sendable (AuthenticatedSessionIdentity) -> Bool,
                 start: @escaping @MainActor @Sendable (AuthenticatedSessionIdentity) async -> Void,
                 retire: @escaping @MainActor @Sendable (Retirement) async -> Void) {
        self.current = current; self.start = start; self.retire = retire
    }

    package func isCurrent(_ value: AuthenticatedSessionIdentity) -> Bool {
        !suspended && !stopped && identity == value && current(value)
    }

    /// Returns the owned work so callers can join startup or retirement.
    package func update(_ value: AuthenticatedSessionIdentity?) -> Task<Void, Never> {
        guard !stopped, signedIn != (value != nil) else { return Task {} }
        signedIn = value != nil
        identity = value
        return Task {
            if let value, !suspended { await start(value) }
            else { await retire(.session) }
        }
    }

    package func suspend() -> Task<Void, Never> {
        suspended = true
        return Task { await retire(.session) }
    }

    package func resume(_ value: AuthenticatedSessionIdentity?) -> Task<Void, Never> {
        suspended = false
        return update(value)
    }

    package func refresh(_ value: AuthenticatedSessionIdentity?) -> Task<Void, Never> {
        guard !stopped, !suspended, let value, current(value) else { return Task {} }
        identity = value
        return Task { await start(value) }
    }

    package func stop() -> Task<Void, Never> {
        stopped = true
        return Task { await retire(.quit) }
    }
}
