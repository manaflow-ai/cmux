import Foundation

/// The viewer's whole lifecycle as one pure transition function.
///
/// Rules that keep the stream un-flaky live here, in testable form:
/// - every path back to a working stream goes through exactly one action,
///   `.openLaneAndStart` (stateless reattach; no partial recoveries),
/// - transport loss, decode stall, watchdog expiry, and host restarts all
///   funnel into the same `retry(after:)` flow with bounded backoff,
/// - backoff resets the moment a frame actually presents, so a healthy
///   stream never pays for an earlier outage.
public struct SimStreamViewerLifecycle: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// Waiting for the transport to report a usable connection.
        case waitingForTransport
        /// Lane dialing + `start` in flight, awaiting `config`.
        case starting
        case streaming
        /// Tear down, wait `delay`, then reattach.
        case retrying(delay: TimeInterval)
        case backgrounded
        /// Host said the stream cannot exist (device gone, panel closed).
        case unavailable(reason: String)
        case stopped
    }

    public enum Event: Sendable, Equatable {
        case activate
        case deactivate
        case transportReady
        case transportLost
        case startSucceeded
        case framePresented
        /// Decoder gave up (repeated failures) or watchdog saw no progress.
        case streamWedged(reason: String)
        case hostEnded(status: SimStreamHostStatus, detail: String)
        case retryDelayElapsed
        case appBackgrounded
        case appForegrounded
    }

    public enum Action: Sendable, Equatable {
        case none
        /// Open the lane, send `start`, begin reading. The single reattach path.
        case openLaneAndStart
        /// Stop reading, close the lane, tear down the decoder.
        case teardown
        /// Teardown, then deliver `.retryDelayElapsed` after the delay.
        case teardownAndRetry(after: TimeInterval)
    }

    public struct Backoff: Sendable, Equatable {
        public var attempt: Int = 0
        public var base: TimeInterval
        public var ceiling: TimeInterval

        public init(base: TimeInterval = 0.25, ceiling: TimeInterval = 4.0) {
            self.base = base
            self.ceiling = ceiling
        }

        public mutating func nextDelay() -> TimeInterval {
            let delay = min(base * pow(2, Double(attempt)), ceiling)
            attempt += 1
            return delay
        }

        public mutating func reset() {
            attempt = 0
        }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var backoff: Backoff

    public init(backoff: Backoff = Backoff()) {
        self.backoff = backoff
    }

    @discardableResult
    public mutating func handle(_ event: Event) -> Action {
        switch (phase, event) {
        // Activation
        case (.idle, .activate), (.stopped, .activate), (.unavailable, .activate):
            phase = .waitingForTransport
            return .none
        case (.waitingForTransport, .transportReady):
            phase = .starting
            return .openLaneAndStart

        // Steady state
        case (.starting, .startSucceeded):
            phase = .streaming
            return .none
        case (.streaming, .framePresented):
            backoff.reset()
            return .none

        // Failure funnel: one recovery path for every wedge.
        case (.starting, .transportLost),
            (.starting, .streamWedged),
            (.streaming, .transportLost),
            (.streaming, .streamWedged):
            let delay = backoff.nextDelay()
            phase = .retrying(delay: delay)
            return .teardownAndRetry(after: delay)
        case (.retrying, .retryDelayElapsed):
            phase = .waitingForTransport
            return .none
        case (.waitingForTransport, .transportLost),
            (.retrying, .transportLost):
            return .none

        // Host-declared endings are terminal until reactivated; retrying
        // into a closed panel would loop forever.
        case (_, .hostEnded(let status, let detail)):
            guard phase != .idle, phase != .stopped else { return .none }
            phase = .unavailable(reason: detail.isEmpty ? "\(status)" : detail)
            return .teardown

        // Background/foreground
        case (.idle, .appBackgrounded), (.stopped, .appBackgrounded):
            return .none
        case (_, .appBackgrounded):
            phase = .backgrounded
            return .teardown
        case (.backgrounded, .appForegrounded):
            backoff.reset()
            phase = .waitingForTransport
            return .none

        // Deactivation
        case (_, .deactivate):
            let wasActive = phase != .idle && phase != .stopped
            phase = .stopped
            return wasActive ? .teardown : .none

        default:
            return .none
        }
    }

    /// Re-arms the machine when the transport becomes ready while retrying
    /// or waiting; safe to call on every transport-ready edge.
    public mutating func noteTransportReadyEdge() -> Action {
        handle(.transportReady)
    }
}
