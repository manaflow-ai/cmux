/// Tracks the number and aggregate size of messages waiting to be sent.
///
/// The owning transport actor must be the only caller; the reference semantics
/// let synchronous queue operations reserve and release the same budget.
public final class WorkspaceSharePendingSendBudget {
    /// The maximum number of messages that may be pending.
    public let maximumMessages: Int

    /// The maximum aggregate payload size that may be pending.
    public let maximumBytes: Int

    /// The number of messages currently reserved.
    public private(set) var pendingMessages: Int

    /// The aggregate payload size currently reserved.
    public private(set) var pendingBytes: Int

    /// Creates an empty pending-send budget.
    ///
    /// - Parameters:
    ///   - maximumMessages: Maximum pending message count. Negative values are treated as zero.
    ///   - maximumBytes: Maximum pending payload bytes. Negative values are treated as zero.
    public init(maximumMessages: Int, maximumBytes: Int) {
        self.maximumMessages = max(0, maximumMessages)
        self.maximumBytes = max(0, maximumBytes)
        self.pendingMessages = 0
        self.pendingBytes = 0
    }

    /// Reserves capacity for one message when both limits permit it.
    ///
    /// - Parameter byteCount: Encoded payload size. Negative values are rejected.
    /// - Returns: `true` when the reservation was accepted.
    @discardableResult
    public func reserve(byteCount: Int) -> Bool {
        guard byteCount >= 0,
              pendingMessages < maximumMessages,
              byteCount <= maximumBytes - pendingBytes else {
            return false
        }
        pendingMessages += 1
        pendingBytes += byteCount
        return true
    }

    /// Releases one completed message reservation.
    ///
    /// - Parameter byteCount: Encoded payload size used for the matching reservation.
    public func release(byteCount: Int) {
        guard pendingMessages > 0, byteCount >= 0 else { return }
        pendingMessages -= 1
        pendingBytes = max(0, pendingBytes - byteCount)
    }

    /// Clears every pending reservation.
    public func reset() {
        pendingMessages = 0
        pendingBytes = 0
    }
}
