/// Admission policy for decoded mobile RPC frames awaiting a response.
///
/// The host evaluates this policy and inserts the admitted task within the same
/// actor turn. This bounds both request-handler tasks and waiters on the shared
/// serialized response writer for every byte transport.
public struct MobileHostRPCWorkQuota: Sendable {
    /// Keeps useful request concurrency while bounding per-connection tasks.
    public static let recommendedMaximumConcurrentRequestCount = 16

    /// One connection may retain at most one protocol-sized frame of decoded
    /// request data across all in-flight handlers.
    public static let recommendedMaximumAggregateFrameByteCount =
        MobileSyncFrameCodec.defaultMaximumFrameByteCount

    public let maximumConcurrentRequestCount: Int
    public let maximumAggregateFrameByteCount: Int

    public init(
        maximumConcurrentRequestCount: Int = Self
            .recommendedMaximumConcurrentRequestCount,
        maximumAggregateFrameByteCount: Int = Self
            .recommendedMaximumAggregateFrameByteCount
    ) {
        precondition(maximumConcurrentRequestCount > 0)
        precondition(maximumAggregateFrameByteCount > 0)
        self.maximumConcurrentRequestCount = maximumConcurrentRequestCount
        self.maximumAggregateFrameByteCount = maximumAggregateFrameByteCount
    }

    /// Returns whether one more decoded frame fits both request budgets.
    ///
    /// Subtraction from the remaining budget avoids overflowing when evaluating
    /// malformed or defensive caller-provided counts.
    public func allowsAdmission<ActiveFrameByteCounts: Sequence>(
        frameByteCount: Int,
        activeFrameByteCounts: ActiveFrameByteCounts
    ) -> Bool where ActiveFrameByteCounts.Element == Int {
        guard frameByteCount >= 0,
              frameByteCount <= maximumAggregateFrameByteCount else {
            return false
        }

        var activeRequestCount = 0
        var remainingByteCount = maximumAggregateFrameByteCount - frameByteCount
        for activeFrameByteCount in activeFrameByteCounts {
            activeRequestCount += 1
            guard activeRequestCount < maximumConcurrentRequestCount,
                  activeFrameByteCount >= 0,
                  activeFrameByteCount <= remainingByteCount else {
                return false
            }
            remainingByteCount -= activeFrameByteCount
        }
        return true
    }
}
