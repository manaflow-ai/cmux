import os

/// Receive credit per reliable lane (E1): the sequence after the last
/// fragment of the last frame the consumer took from the inbox, and what the
/// last ack advertised. Written from the consumer's task (`onConsume`), read
/// by the transport's pump when it builds an ack.
final class ReceiveCredit: Sendable {
    private struct Lane {
        var consumed: UInt32 = 0
        var advertised: UInt32 = 0
    }

    // carve-out: one comparison per consumed frame from the consumer's
    // task, never held across a suspension; avoids an actor hop per frame.
    private let state = OSAllocatedUnfairLock(initialState: [LaneID: Lane]())

    /// The consumer took a frame of `lane` ending at `end`. True when the
    /// credit moved `threshold` fragments past the last advertised value, so
    /// a sender waiting for credit should hear about it now.
    func consumed(_ lane: LaneID, end: UInt32, threshold: UInt32) -> Bool {
        state.withLock { lanes in
            var entry = lanes[lane] ?? Lane()
            if end > entry.consumed { entry.consumed = end }
            lanes[lane] = entry
            return entry.consumed - entry.advertised >= threshold
        }
    }

    /// The credit to put in an ack now; recorded as advertised.
    func advertise(_ lane: LaneID) -> UInt32 {
        state.withLock { lanes in
            var entry = lanes[lane] ?? Lane()
            entry.advertised = entry.consumed
            lanes[lane] = entry
            return entry.consumed
        }
    }
}
