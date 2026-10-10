import Foundation

// Checked access (plans/cmux-next/crash-elimination.md, classes index_subscript
// and int_conversion). An index that comes from daemon data or from arithmetic
// is used through these helpers, which return nil or false instead of trapping.

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

    /// Calls `body` with the first element that matches `predicate` and returns
    /// true; false when none matches.
    @discardableResult
    mutating func modifyFirst(
        where predicate: (Element) throws -> Bool,
        _ body: (inout Element) throws -> Void
    ) rethrows -> Bool {
        guard let index = try firstIndex(where: predicate) else { return false }
        return try modify(checked: index, body)
    }
}

extension BinaryFloatingPoint {
    /// The value rounded toward zero as `I`, saturated at `I`'s bounds; nil for NaN.
    /// For daemon numbers where the nearest representable value is the right
    /// meaning (`Int(x)` traps for NaN, infinity or out of range).
    func saturatedInteger<I: FixedWidthInteger>(_: I.Type = I.self) -> I? {
        guard !isNaN else { return nil }
        if self >= Self(I.max) { return I.max }
        if self <= Self(I.min) { return I.min }
        return I(exactly: rounded(.towardZero))
    }
}
