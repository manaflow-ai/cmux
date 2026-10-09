import Foundation

/// The 12-byte TAI64N timestamp in a handshake initiation: big-endian
/// seconds plus 2^62 + 10, then big-endian nanoseconds. Responders keep the
/// greatest one per peer and refuse anything not newer (replay defence).
struct TAI64N: Comparable {
    let bytes: [UInt8]

    init(date: Date) {
        let interval = date.timeIntervalSince1970
        let seconds = UInt64(max(0, interval.rounded(.down))) &+ 0x4000_0000_0000_000A
        let nanos = UInt32(max(0, min(999_999_999, (interval - interval.rounded(.down)) * 1e9)))
        var out: [UInt8] = []
        for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: seconds >> UInt64(shift))) }
        for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: nanos >> UInt32(shift))) }
        bytes = out
    }

    init?(bytes: [UInt8]) {
        guard bytes.count == 12 else { return nil }
        self.bytes = bytes
    }

    static func < (lhs: TAI64N, rhs: TAI64N) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}
