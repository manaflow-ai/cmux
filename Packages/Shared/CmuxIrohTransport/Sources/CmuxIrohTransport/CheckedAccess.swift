import Foundation

// Checked access for decoders (plans/cmux-next/crash-elimination.md, classes
// index_subscript and int_conversion). Reads that come from the wire or from
// arithmetic return nil instead of trapping; the caller turns nil into its typed
// error or refuses the input.

/// Reads fixed-width fields from wire bytes front to back. Every read returns
/// nil when too few bytes remain, so a decoder never computes a byte index.
struct WireByteReader {
    private var rest: Data

    init(_ data: Data) {
        rest = data
    }

    /// Bytes not read yet.
    var remaining: Data { Data(rest) }
    var remainingCount: Int { rest.count }

    /// The next `count` bytes, or nil (nothing consumed) when fewer remain.
    mutating func bytes(_ count: some BinaryInteger) -> Data? {
        guard let count = Int(exactly: count), count >= 0, rest.count >= count else { return nil }
        let field = Data(rest.prefix(count))
        rest = rest.dropFirst(count)
        return field
    }

    mutating func byte() -> UInt8? {
        rest.popFirst()
    }

    /// A big-endian unsigned integer of `T`'s width.
    mutating func bigEndian<T: FixedWidthInteger & UnsignedInteger>(_: T.Type = T.self) -> T? {
        guard let field = bytes(MemoryLayout<T>.size) else { return nil }
        // Every unsigned fixed-width type holds a whole byte: the widening T(byte) cannot trap.
        return field.reduce(T.zero) { ($0 << 8) | T($1) }
    }
}

extension Int {
    /// Identity generations are 1...Int32.max (a stored record keeps 32 bits).
    var isValidIdentityGeneration: Bool {
        self >= 1 && self <= Int32.max
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
}

extension Substring {
    /// "[host]rest" split into the text between the brackets and the text after
    /// the first "]"; nil when the text does not start with "[" or has no "]".
    var bracketedHost: (host: Substring, rest: Substring)? {
        guard first == "[" else { return nil }
        let parts = dropFirst().split(separator: "]", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let host = parts.first, let rest = parts.last else { return nil }
        return (host, rest)
    }

    /// The text before and after the last ":"; nil when there is no ":".
    var splitAtLastColon: (head: Substring, tail: Substring)? {
        guard contains(":"), let tail = split(separator: ":", omittingEmptySubsequences: false).last else {
            return nil
        }
        return (dropLast(tail.count + 1), tail)
    }
}
