import Foundation

/// Caps how many concurrent Stack network verifications the unauthenticated
/// `mobile.host.status` identity gate may have in flight. Status is reachable
/// without credentials, so without a cap a peer that can reach the pairing
/// port could mint unique garbage tokens and queue an unbounded backlog of
/// 10s-timeout Stack lookups. Over the cap the status reply simply withholds
/// identity (cheap), which the client's identity-recovery retry tolerates.
/// Authorized verbs do not pass through this limiter; their verification
/// posture is unchanged.
actor MobileHostStatusVerificationLimiter {
    static let shared = MobileHostStatusVerificationLimiter()

    private var inFlight = 0
    private var authorizationInFlight = 0
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    private let limit: Int
    private let authorizationLimit: Int

    init(limit: Int = 2, authorizationLimit: Int = 4) {
        self.limit = limit
        self.authorizationLimit = max(1, authorizationLimit)
    }

    /// Take a verification slot. `false` when saturated; the caller must
    /// degrade (withhold identity), not wait.
    func acquire() -> Bool {
        guard inFlight < limit else {
            return false
        }
        inFlight += 1
        return true
    }

    /// Return a slot taken with a successful ``acquire()``.
    func release() {
        assert(inFlight > 0, "release without a matching acquire")
        inFlight = max(0, inFlight - 1)
    }

    /// Run an authorized-RPC Stack verification behind an awaitable shared cap.
    /// Unlike status probes, callers wait for a slot so legitimate authorized
    /// requests keep their normal auth semantics under the cap.
    func withAuthorizationPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        await acquireAuthorizationPermit()
        if Task.isCancelled {
            releaseAuthorizationPermit()
            throw CancellationError()
        }
        do {
            let value = try await operation()
            releaseAuthorizationPermit()
            return value
        } catch {
            releaseAuthorizationPermit()
            throw error
        }
    }

    private func acquireAuthorizationPermit() async {
        if authorizationInFlight < authorizationLimit {
            authorizationInFlight += 1
            return
        }
        await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
        }
    }

    private func releaseAuthorizationPermit() {
        if authorizationWaiters.isEmpty {
            authorizationInFlight = max(0, authorizationInFlight - 1)
        } else {
            let waiter = authorizationWaiters.removeFirst()
            waiter.resume()
        }
    }
}
