import Foundation

// Checked conversions (plans/cmux-next/crash-elimination.md, class int_conversion).

extension BinaryFloatingPoint {
    /// The value rounded toward zero as `I`, saturated at `I`'s bounds; nil for NaN.
    /// For durations and counters where the nearest representable value is the
    /// right meaning (`Int(x)` traps for NaN, infinity or out of range).
    func saturatedInteger<I: FixedWidthInteger>(_: I.Type = I.self) -> I? {
        guard !isNaN else { return nil }
        if self >= Self(I.max) { return I.max }
        if self <= Self(I.min) { return I.min }
        return I(exactly: rounded(.towardZero))
    }
}

extension FixedWidthInteger {
    /// `self * other`, saturated at the type's bounds instead of trapping.
    func saturatingMultiplication(_ other: Self) -> Self {
        let (product, overflow) = multipliedReportingOverflow(by: other)
        guard overflow else { return product }
        return (self < 0) != (other < 0) ? .min : .max
    }

    /// `self + other`, saturated at the type's bounds instead of trapping.
    func saturatingAddition(_ other: Self) -> Self {
        let (sum, overflow) = addingReportingOverflow(other)
        guard overflow else { return sum }
        return other < 0 ? .min : .max
    }
}
