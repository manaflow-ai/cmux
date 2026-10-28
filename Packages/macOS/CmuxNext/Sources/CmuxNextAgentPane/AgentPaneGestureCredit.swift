import Foundation

/// What a frame that took the person's gesture leaves for one later frame on the same connection
/// (``AgentPaneTransport/startCredit``, ``AgentPaneTransport/remoteTrustCredit``): the connection
/// and the uptime it was given at. Spending it clears it.
struct AgentPaneGestureCredit {
    private var held: (connection: Int, at: TimeInterval)?

    mutating func give(connection: Int, at: TimeInterval) { held = (connection, at) }

    mutating func clear() { held = nil }

    /// Spends the credit on `connection`: nil when there is none on it, else whether it is still
    /// within `lifetime` at `now`. `dropOthers`: a credit on another connection is cleared too.
    mutating func take(connection: Int, now: TimeInterval, lifetime: TimeInterval, dropOthers: Bool = false) -> Bool? {
        guard let credit = held, dropOthers || credit.connection == connection else { return nil }
        held = nil
        guard credit.connection == connection else { return nil }
        return now - credit.at <= lifetime
    }
}
