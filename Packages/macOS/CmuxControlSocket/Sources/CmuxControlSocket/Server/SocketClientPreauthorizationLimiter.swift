/// Bounds concurrent socket clients waiting to prove authorization.
public actor SocketClientPreauthorizationLimiter {
    private let maximumConcurrentClaims: Int
    private var activeClaims = 0

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
        guard activeClaims < maximumConcurrentClaims else { return false }
        activeClaims += 1
        return true
    }

    /// Releases one previously claimed reader slot.
    public func release() {
        guard activeClaims > 0 else { return }
        activeClaims -= 1
    }
}
