import Foundation

// Checked access for decoders (plans/cmux-next/crash-elimination.md, classes
// index_subscript and int_conversion). Reads that come from the wire or from
// arithmetic return nil instead of trapping; the caller turns nil into its typed
// error or refuses the input.

/// Reads fixed-width fields from wire bytes front to back. Every read returns
/// nil (and consumes nothing) when too few bytes remain, so a decoder never
/// computes a byte index.
struct WireByteReader {
    private var rest: Data

    init(_ data: Data) {
        rest = data
    }

    /// Bytes not read yet.
    var remaining: Data { Data(rest) }
    var remainingCount: Int { rest.count }

    /// The next `count` bytes, or nil when fewer remain.
    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, rest.count >= count else { return nil }
        let field = Data(rest.prefix(count))
        rest = rest.dropFirst(count)
        return field
    }

    /// Skips `count` bytes; false (nothing skipped) when fewer remain.
    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, rest.count >= count else { return false }
        rest = rest.dropFirst(count)
        return true
    }

    /// A big-endian unsigned integer of `T`'s width.
    mutating func bigEndian<T: FixedWidthInteger & UnsignedInteger>(_: T.Type = T.self) -> T? {
        guard let field = bytes(MemoryLayout<T>.size) else { return nil }
        // Every unsigned fixed-width type holds a whole byte: the widening T(byte) cannot trap.
        return field.reduce(T.zero) { ($0 << 8) | T($1) }
    }
}

extension FixedWidthInteger {
    /// `self - other`, saturated at the type's bounds instead of trapping on
    /// overflow (server timestamps are any Int on the wire).
    func saturatingSubtraction(_ other: Self) -> Self {
        let (difference, overflow) = subtractingReportingOverflow(other)
        guard overflow else { return difference }
        return other < 0 ? .max : .min
    }
}

extension BinaryFloatingPoint {
    /// The value rounded toward zero as `I`, saturated at `I`'s bounds; nil for NaN.
    /// For wall-clock and duration values where the nearest representable value is
    /// the right meaning (`Int(x)` traps for NaN, infinity or out of range).
    func saturatedInteger<I: FixedWidthInteger>(_: I.Type = I.self) -> I? {
        guard !isNaN else { return nil }
        if self >= Self(I.max) { return I.max }
        if self <= Self(I.min) { return I.min }
        return I(exactly: rounded(.towardZero))
    }

    /// Whole seconds (or any unit) for a journal field: saturated, "nan" for NaN.
    var journalInteger: String {
        saturatedInteger(Int.self).map(String.init) ?? "nan"
    }
}
