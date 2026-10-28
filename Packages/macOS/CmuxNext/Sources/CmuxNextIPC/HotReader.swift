// The reader half of the hot-message codec (HotLayout.swift).

import Foundation

/// Reads values off a payload, little endian.
public struct HotReader: Sendable {
    private let bytes: [UInt8]
    private var index: Int

    init(bytes: [UInt8], start: Int) {
        self.bytes = bytes
        self.index = start
    }

    /// The bytes not read yet.
    public var remaining: Int { bytes.count - index }

    public mutating func bool() throws(HotDecodeError) -> Bool {
        switch try byte() {
        case 0: false
        case 1: true
        case let other: throw .badBool(other)
        }
    }

    /// The byte before an optional or nullable field: true when a value follows.
    public mutating func tag() throws(HotDecodeError) -> Bool {
        switch try byte() {
        case 0: false
        case 1: true
        case let other: throw .badTag(other)
        }
    }

    public mutating func enumeration() throws(HotDecodeError) -> UInt8 {
        try byte()
    }

    public mutating func u16() throws(HotDecodeError) -> UInt16 { try fixed(UInt16.self) }
    public mutating func u32() throws(HotDecodeError) -> UInt32 { try fixed(UInt32.self) }
    public mutating func u64() throws(HotDecodeError) -> UInt64 { try fixed(UInt64.self) }
    public mutating func i32() throws(HotDecodeError) -> Int32 { Int32(bitPattern: try fixed(UInt32.self)) }
    public mutating func i64() throws(HotDecodeError) -> Int64 { Int64(bitPattern: try fixed(UInt64.self)) }
    public mutating func f32() throws(HotDecodeError) -> Float { Float(bitPattern: try fixed(UInt32.self)) }
    public mutating func f64() throws(HotDecodeError) -> Double { Double(bitPattern: try fixed(UInt64.self)) }

    public mutating func string(max: UInt16) throws(HotDecodeError) -> String {
        let length = try lengthPrefix(max: max)
        guard remaining >= length else { throw .truncated }
        let utf8 = bytes[index..<(index + length)]
        index += length
        guard let value = String(bytes: utf8, encoding: .utf8) else { throw .invalidUTF8 }
        return value
    }

    /// The u16 count before an array's items, at most `max`.
    public mutating func count(max: UInt16) throws(HotDecodeError) -> Int {
        try lengthPrefix(max: max)
    }

    private mutating func lengthPrefix(max: UInt16) throws(HotDecodeError) -> Int {
        let length = try u16()
        guard length <= max else { throw .overBound(length: Int(length), max: max) }
        return Int(length)
    }

    private mutating func byte() throws(HotDecodeError) -> UInt8 {
        guard remaining >= 1 else { throw .truncated }
        defer { index += 1 }
        return bytes[index]
    }

    private mutating func fixed<Value: FixedWidthInteger & UnsignedInteger>(_: Value.Type) throws(HotDecodeError) -> Value {
        let size = Value.bitWidth / 8
        guard remaining >= size else { throw .truncated }
        var value: Value = 0
        for offset in 0..<size {
            value |= Value(bytes[index + offset]) << (8 * offset)
        }
        index += size
        return value
    }
}
