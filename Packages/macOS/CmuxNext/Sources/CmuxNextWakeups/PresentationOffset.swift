/// The per-OS constant from the render server's frame to the glass, calibrated by the glass check
/// (DC3, `input-glass-check`). Zero until a calibration for that macOS version is recorded here.
public struct PresentationOffset: Sendable, Hashable {
    /// Calibrated offsets by macOS major version, in nanoseconds (DC3 fills this table).
    private static let calibrated: [Int: Int64] = [:]

    /// Nanoseconds added to each estimate (negative moves it earlier).
    public let nanos: Int64

    /// An offset of `nanos` nanoseconds.
    public init(nanos: Int64) {
        self.nanos = nanos
    }

    /// The calibrated offset of macOS `osMajorVersion`, or zero.
    public init(osMajorVersion: Int) {
        self.init(nanos: Self.calibrated[osMajorVersion] ?? 0)
    }

    /// `time` moved by the offset, never below zero.
    func applied(to time: UInt64) -> UInt64 {
        if nanos >= 0 { return time + UInt64(nanos) }
        let earlier = nanos.magnitude
        return time > earlier ? time - earlier : 0
    }
}
