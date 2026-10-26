import Foundation

// Checked access for the RFB decoders (plans/cmux-next/chrome-parity/p10-stability.md, section D: outside input
// never traps). A server's bytes are untrusted input: a decoder reads fields through these helpers, which have no
// index of their own and no trapping conversion, and turns a nil into `RFBError.protocolViolation`. The decode
// files (scripts/cmux-next/decode-paths.json) take no raw subscript or `Int(x)` at all; the guardrail
// `decode-trap` refuses one there before a push.

extension Collection {
    /// The element at `index`, or nil when `index` is outside the collection.
    subscript(checked index: Index) -> Element? {
        guard index >= startIndex, index < endIndex else { return nil }
        return self[index] // crash-allow: startIndex <= index < endIndex checked above
    }
}

extension Collection<UInt8> {
    /// The bytes as one big-endian unsigned integer (RFC 6143 sends every count and coordinate this way). Each byte
    /// widens into the result, which `truncatingIfNeeded:` does exactly from the narrower `UInt8`; callers pass the
    /// bytes of one field.
    package func bigEndian<Value: FixedWidthInteger & UnsignedInteger>(as _: Value.Type = Value.self) -> Value {
        reduce(Value.zero) { $0 << 8 | Value(truncatingIfNeeded: $1) }
    }
}

extension BidirectionalCollection<UInt8> {
    /// The bytes as one little-endian unsigned integer (the negotiated BGRX pixel).
    package func littleEndian<Value: FixedWidthInteger & UnsignedInteger>(as _: Value.Type = Value.self) -> Value {
        reversed().reduce(Value.zero) { $0 << 8 | Value(truncatingIfNeeded: $1) }
    }
}

extension UInt8 {
    /// The byte as an `Int` (a widening: exact).
    package var widened: Int { Int(truncatingIfNeeded: self) }
}

extension UInt16 {
    /// The value as an `Int` (a widening: exact, `Int` has at least 32 bits).
    package var widened: Int { Int(truncatingIfNeeded: self) }
}

extension UInt32 {
    /// The value as an `Int`, or `RFBError.protocolViolation` naming `what` when it does not fit (a 32-bit `Int`).
    func rfbCount(_ what: @autoclosure () -> String) throws -> Int {
        guard let value = Int(exactly: self) else { throw RFBError.protocolViolation("\(what()) \(self) does not fit") }
        return value
    }
}
