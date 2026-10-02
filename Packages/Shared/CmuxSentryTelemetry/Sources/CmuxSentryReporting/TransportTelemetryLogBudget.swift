import Foundation

/// A sliding-window admission budget for structured transport log lines.
///
/// Sentry structured logs are quota-billed per entry, and a transport retry
/// storm can emit an event every few seconds for hours. This budget admits up
/// to `capacityPerHour` entries per sliding hour (measured in the event
/// stream's monotonic time) and counts what it drops, so the first admitted
/// entry after a drop window can report how much was suppressed.
struct TransportTelemetryLogBudget: Sendable {
    private let capacityPerHour: Int
    private var window: [UInt64] = []
    private var droppedSinceLastAdmit = 0

    init(capacityPerHour: Int) {
        self.capacityPerHour = max(1, capacityPerHour)
    }

    /// Admits or drops one log line at the given monotonic timestamp.
    ///
    /// - Returns: `nil` when the line should be dropped; otherwise the number
    ///   of lines dropped since the previous admitted one (0 when none).
    mutating func admit(tNanos: UInt64) -> Int? {
        let windowNanos: UInt64 = 3_600_000_000_000
        window.removeAll { tNanos >= $0 && tNanos - $0 > windowNanos }
        guard window.count < capacityPerHour else {
            droppedSinceLastAdmit += 1
            return nil
        }
        window.append(tNanos)
        let dropped = droppedSinceLastAdmit
        droppedSinceLastAdmit = 0
        return dropped
    }
}
