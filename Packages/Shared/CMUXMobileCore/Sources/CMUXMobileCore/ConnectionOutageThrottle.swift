import Foundation

/// Pure decision logic that collapses connection-state edges into at most one
/// `ios_connection_lost` per outage and one `ios_connection_recovered` per
/// recovery.
///
/// A flapping link sets `connectionState` to `.disconnected` and back many times;
/// instrumenting every assignment would spam. This type tracks only whether an
/// outage is currently open and emits an event solely on the *edge* between
/// connected and disconnected. It holds no reference state and is `Sendable`; the
/// caller threads the small `Bool` of outage state through ``record(transition:)``.
///
/// ```swift
/// var throttle = ConnectionOutageThrottle()
/// if let signal = throttle.record(transition: .init(wasConnected: true, isConnected: false)) {
///     // signal == .lost — emit exactly once for this outage.
/// }
/// ```
public struct ConnectionOutageThrottle: Sendable, Equatable {
    /// Whether an outage is currently open (a lost event has fired with no
    /// matching recovered event yet).
    public private(set) var outageOpen: Bool

    /// Creates a throttle, optionally pre-seeded with an open outage.
    /// - Parameter outageOpen: The initial outage state. Defaults to `false`.
    public init(outageOpen: Bool = false) {
        self.outageOpen = outageOpen
    }

    /// A connected/disconnected transition observed on the shell store.
    public struct Transition: Sendable, Equatable {
        /// Whether the connection was connected before the transition.
        public let wasConnected: Bool
        /// Whether the connection is connected after the transition.
        public let isConnected: Bool

        /// Creates a transition.
        public init(wasConnected: Bool, isConnected: Bool) {
            self.wasConnected = wasConnected
            self.isConnected = isConnected
        }
    }

    /// The throttled outcome of a transition.
    public enum Signal: Sendable, Equatable {
        /// The connection just went down and no outage was already open.
        case lost
        /// The connection just came back and an outage was open.
        case recovered
    }

    /// Records a transition and returns the event to emit, if any.
    ///
    /// Mutates ``outageOpen`` so a subsequent flap on the same edge is suppressed.
    /// Returns `.lost` only on the first connected→disconnected edge of an outage,
    /// and `.recovered` only on the disconnected→connected edge that closes an
    /// open outage.
    ///
    /// - Parameter transition: The observed connection-state transition.
    /// - Returns: The ``Signal`` to emit, or `nil` if the transition is a no-op
    ///   for analytics (a repeated state, or a recovery with no open outage).
    public mutating func record(transition: Transition) -> Signal? {
        let wentDown = transition.wasConnected && !transition.isConnected
        let cameUp = !transition.wasConnected && transition.isConnected

        if wentDown {
            guard !outageOpen else { return nil }
            outageOpen = true
            return .lost
        }
        if cameUp {
            guard outageOpen else { return nil }
            outageOpen = false
            return .recovered
        }
        return nil
    }
}
