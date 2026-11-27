import Foundation

/// Which kept failures a remote sink (Sentry on the Mac) sends as their own event, beyond the
/// breadcrumb every kept record becomes.
///
/// - ``ConnectivityAudience/team``: every failure.
/// - ``ConnectivityAudience/everyone``: one event per failure key per ``everyoneInterval``, so a
///   retry storm on one person's Mac is one issue an hour, never thousands.
public struct ConnectivityRemoteGate: Sendable {
    public let everyoneInterval: TimeInterval
    private var lastSent: [String: Date] = [:]

    public init(everyoneInterval: TimeInterval = 3600) {
        self.everyoneInterval = everyoneInterval
    }

    /// Whether `record` goes out as its own event.
    public mutating func sendsEvent(for record: ConnectivityRecord) -> Bool {
        guard record.outcome == .failure else { return false }
        if record.audience == .team { return true }
        if let last = lastSent[record.key], record.date.timeIntervalSince(last) < everyoneInterval { return false }
        lastSent[record.key] = record.date
        return true
    }
}
