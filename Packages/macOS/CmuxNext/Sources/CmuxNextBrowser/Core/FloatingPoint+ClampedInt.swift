import Foundation

extension BinaryFloatingPoint {
    /// Rounded and clamped to Int32 for C APIs: NaN is 0 and infinities
    /// clamp, where `Int32(_:)` would trap.
    nonisolated var clampedInt32: Int32 {
        guard isFinite else { return isNaN ? 0 : (self < 0 ? .min : .max) }
        let rounded = self.rounded()
        if rounded >= Self(Int32.max) { return .max }
        if rounded <= Self(Int32.min) { return .min }
        return Int32(rounded)
    }
}
