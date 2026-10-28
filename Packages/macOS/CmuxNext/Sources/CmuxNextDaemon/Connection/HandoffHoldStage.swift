extension DaemonConnection {
    /// How a quiet handoff's hold of new requests ended (``DaemonConnection/quietHandoff(_:)``).
    public enum HandoffHoldEnd: String, Sendable, CaseIterable {
        /// A new connection was ready: the held requests went to the next daemon.
        case ready
        /// The daemon refused the handoff, or its request failed: the held requests went to the running daemon.
        case refused
        /// The connection closed for good: the held requests went on and failed as not connected.
        case closed
        /// ``DaemonConnection/handoffHoldLimit`` passed with no new connection ready: the held requests failed
        /// with ``DaemonError/handoffNotReady``.
        case limit
    }

    /// The quiet handoff's hold as a measured stage (`debug.daemon`'s `handoff_hold`): how many holds
    /// ended and how, how many requests they held, and how long each held them, from the hold's start (the
    /// handoff waits for quiet with new requests held already) to its end.
    public struct HandoffHoldStage: Sendable, Equatable {
        /// One hold.
        public struct Hold: Sendable, Equatable {
            /// How it ended; nil while it runs.
            public var end: HandoffHoldEnd?
            /// How long it held new requests (so far, while it runs).
            public var duration: Duration
            /// The requests it parked (a request that parked again under a later hold counts there too).
            public var heldRequests: Int
        }

        /// Ended holds by how they ended.
        public var ends: [HandoffHoldEnd: Int] = [:]
        /// Requests parked by the ended holds.
        public var heldRequests = 0
        /// The most requests one ended hold parked.
        public var maxHeldRequests = 0
        /// The longest ended hold.
        public var maxDuration: Duration = .zero
        /// The last ended hold.
        public var last: Hold?
        /// The running hold, nil when none runs.
        public var running: Hold?

        /// Holds that ended.
        public var holds: Int { ends.values.reduce(0, +) }

        /// Counts `hold`, which just ended.
        mutating func record(_ hold: Hold) {
            if let end = hold.end { ends[end, default: 0] += 1 }
            heldRequests += hold.heldRequests
            maxHeldRequests = max(maxHeldRequests, hold.heldRequests)
            maxDuration = max(maxDuration, hold.duration)
            last = hold
        }
    }
}
