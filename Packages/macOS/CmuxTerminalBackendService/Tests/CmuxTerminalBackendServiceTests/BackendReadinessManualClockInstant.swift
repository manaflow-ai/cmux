import Foundation

struct BackendReadinessManualClockInstant: InstantProtocol, Sendable {
    var offset: Duration

    func advanced(by duration: Duration) -> BackendReadinessManualClockInstant {
        BackendReadinessManualClockInstant(offset: offset + duration)
    }

    func duration(to other: BackendReadinessManualClockInstant) -> Duration {
        other.offset - offset
    }

    static func < (
        lhs: BackendReadinessManualClockInstant,
        rhs: BackendReadinessManualClockInstant
    ) -> Bool {
        lhs.offset < rhs.offset
    }
}
