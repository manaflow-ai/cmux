import Foundation

// Checked access and conversions (plans/cmux-next/crash-elimination.md, classes
// index_subscript and int_conversion).

extension Collection {
    /// The element at `index`, or nil when `index` is outside the collection.
    subscript(checked index: Index) -> Element? {
        guard index >= startIndex, index < endIndex else { return nil }
        return self[index]
    }
}

extension MutableCollection {
    /// Calls `body` with the element at `index` and returns true; returns false
    /// without calling it when `index` is outside the collection.
    @discardableResult
    mutating func modify(checked index: Index, _ body: (inout Element) throws -> Void) rethrows -> Bool {
        guard index >= startIndex, index < endIndex else { return false }
        try body(&self[index])
        return true
    }
}

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
