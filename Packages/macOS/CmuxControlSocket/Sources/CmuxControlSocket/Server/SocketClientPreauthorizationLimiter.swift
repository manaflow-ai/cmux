internal import os

/// Bounds concurrent socket clients waiting to prove authorization.
///
/// Admission is synchronous because it runs on the listener's Dispatch queue
/// before a dedicated client thread is started. A lock keeps this ingress path
/// independent of Swift's cooperative executor, including when background
/// filesystem or process scans occupy every cooperative worker.
public final class SocketClientPreauthorizationLimiter: Sendable {
    private let maximumConcurrentClaims: Int
    private let activeClaims = OSAllocatedUnfairLock(initialState: 0)

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
        activeClaims.withLock { activeClaims in
            guard activeClaims < maximumConcurrentClaims else { return false }
            activeClaims += 1
            return true
        }
    }

    /// Releases one previously claimed reader slot.
    public func release() {
        activeClaims.withLock { activeClaims in
            guard activeClaims > 0 else { return }
            activeClaims -= 1
        }
    }
}
