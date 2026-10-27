import Foundation

// Checked access for the import readers (plans/cmux-next/chrome-parity/p10-stability.md, section D: outside input
// never traps). A browser's files are untrusted input: a reader takes fields from the front of what is left
// (`prefix`, `dropFirst`, `popFirst`) or through these helpers, which have no index of their own and no trapping
// conversion, and turns a nil into the reader's typed error. The decode files (scripts/cmux-next/decode-paths.json)
// take no raw subscript or `Int(x)` at all; the guardrail `decode-trap` refuses one there before a push.

extension Collection {
    /// The element at `index`, or nil when `index` is outside the collection.
    subscript(checked index: Index) -> Element? {
        guard index >= startIndex, index < endIndex else { return nil }
        return self[index] // crash-allow: startIndex <= index < endIndex checked above
    }
}

extension Collection<UInt8> {
    /// The bytes as one big-endian unsigned integer (Safari's file header, DER lengths). Each byte widens into the
    /// result, which `truncatingIfNeeded:` does exactly from the narrower `UInt8`; callers pass one field's bytes.
    func bigEndian<Value: FixedWidthInteger & UnsignedInteger>(as _: Value.Type = Value.self) -> Value {
        reduce(Value.zero) { $0 << 8 | Value(truncatingIfNeeded: $1) }
    }
}

extension BidirectionalCollection<UInt8> {
    /// The bytes as one little-endian unsigned integer (Safari's cookie pages, Pickle, SNSS, mozLz4).
    func littleEndian<Value: FixedWidthInteger & UnsignedInteger>(as _: Value.Type = Value.self) -> Value {
        reversed().reduce(Value.zero) { $0 << 8 | Value(truncatingIfNeeded: $1) }
    }
}

extension UInt8 {
    /// The byte as an `Int` (a widening: exact).
    var widened: Int { Int(truncatingIfNeeded: self) }
}

extension UInt16 {
    /// The value as an `Int` (a widening: exact).
    var widened: Int { Int(truncatingIfNeeded: self) }
}

extension UInt32 {
    /// The value as an `Int` (a widening: exact, every Mac's `Int` has 64 bits).
    var widened: Int { Int(truncatingIfNeeded: self) }
}

extension Int32 {
    /// The value as an `Int` (a sign-extending widening: exact).
    var widened: Int { Int(truncatingIfNeeded: self) }
}
