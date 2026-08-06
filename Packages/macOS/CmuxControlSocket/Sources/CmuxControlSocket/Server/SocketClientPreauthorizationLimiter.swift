internal import CmuxFoundation

/// Bounds concurrent socket clients waiting to prove authorization.
///
/// Admission is synchronous because it runs on the listener's Dispatch queue
/// before a dedicated client thread is started. An atomic counter keeps this
/// ingress path independent of Swift's cooperative executor, including when
/// background filesystem or process scans occupy every cooperative worker.
public final class SocketClientPreauthorizationLimiter: Sendable {
    private let maximumConcurrentClaims: Int
    private let activeClaims = AtomicUInt64Value()

    /// Creates a limiter with a fixed concurrent claim budget.
    ///
    /// - Parameter maximumConcurrentClaims: Maximum active preauthorization readers.
    public init(maximumConcurrentClaims: Int) {
        self.maximumConcurrentClaims = max(0, maximumConcurrentClaims)
    }

    /// Attempts to reserve one preauthorization reader slot.
    ///
    /// - Returns: `true` when a slot was reserved; otherwise `false`.
    public func claim() -> Bool {
        activeClaims.incrementIfBelow(UInt64(maximumConcurrentClaims))
    }

    /// Releases one previously claimed reader slot.
    public func release() {
        _ = activeClaims.decrementIfPositive()
    }
}
