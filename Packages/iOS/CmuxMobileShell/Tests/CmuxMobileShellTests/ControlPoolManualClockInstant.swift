struct ControlPoolManualClockInstant: InstantProtocol {
    var offset: Duration

    func advanced(by duration: Duration) -> ControlPoolManualClockInstant {
        ControlPoolManualClockInstant(offset: offset + duration)
    }

    func duration(to other: ControlPoolManualClockInstant) -> Duration {
        other.offset - offset
    }

    static func < (
        lhs: ControlPoolManualClockInstant,
        rhs: ControlPoolManualClockInstant
    ) -> Bool {
        lhs.offset < rhs.offset
    }
}
