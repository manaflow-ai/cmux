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
    private let limit: Int

    init(limit: Int = 2) {
        self.limit = limit
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
}
