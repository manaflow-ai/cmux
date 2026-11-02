// SPDX-License-Identifier: GPL-3.0-or-later
import CoreFoundation
import CryptoKit
import Foundation

/// Canonical JSON for app approval digests (docs/computer-use-approvals.md,
/// "The approval question"): object keys sorted by their UTF-8 bytes, no
/// whitespace, UTF-8, and strings escaped exactly as serde_json escapes them
/// (`"` and `\`; `\b \f \n \r \t`; every other control below 0x20 as
/// `\u00xx` in lowercase hex; nothing else, so `/` and non-ASCII stay raw).
/// Numbers are integers only: the wire has no fractions, and float
/// formatting differs between languages. The Rust lanes produce the same
/// bytes; `schemas/computer-use/approval-fixtures.json` is the shared
/// conformance fixture.
enum CanonicalJSON {
    struct UnsupportedValue: Error, Sendable, CustomStringConvertible {
        let description: String
    }

    /// The canonical bytes of a JSON value (`[String: Any]`, `[Any]`,
    /// `String`, an integer or boolean `NSNumber`, `NSNull`).
    static func encode(_ value: Any) throws -> Data {
        var bytes: [UInt8] = []
        try append(value, to: &bytes)
        return Data(bytes)
    }

    /// Lowercase hex SHA-256 of `data`.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ value: Any, to bytes: inout [UInt8]) throws {
        switch value {
        case is NSNull:
            bytes += Array("null".utf8)
        case let string as String:
            appendString(string, to: &bytes)
        case let number as NSNumber:
            try appendNumber(number, to: &bytes)
        case let object as [String: Any]:
            bytes.append(UInt8(ascii: "{"))
            let keys = object.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for (index, key) in keys.enumerated() {
                if index > 0 { bytes.append(UInt8(ascii: ",")) }
                appendString(key, to: &bytes)
                bytes.append(UInt8(ascii: ":"))
                try append(object[key] ?? NSNull(), to: &bytes)
            }
            bytes.append(UInt8(ascii: "}"))
        case let array as [Any]:
            bytes.append(UInt8(ascii: "["))
            for (index, element) in array.enumerated() {
                if index > 0 { bytes.append(UInt8(ascii: ",")) }
                try append(element, to: &bytes)
            }
            bytes.append(UInt8(ascii: "]"))
        default:
            throw UnsupportedValue(description: "canonical JSON cannot encode \(type(of: value))")
        }
    }

    private static func appendNumber(_ number: NSNumber, to bytes: inout [UInt8]) throws {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            bytes += Array((number.boolValue ? "true" : "false").utf8)
            return
        }
        guard !CFNumberIsFloatType(number) || number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue.magnitude < 9.007_199_254_740_992e15 else {
            throw UnsupportedValue(description: "canonical JSON numbers are integers below 2^53")
        }
        bytes += Array(String(number.int64Value).utf8)
    }

    private static func appendString(_ string: String, to bytes: inout [UInt8]) {
        let hex = Array("0123456789abcdef".utf8)
        bytes.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): bytes += [UInt8(ascii: "\\"), UInt8(ascii: "\"")]
            case UInt8(ascii: "\\"): bytes += [UInt8(ascii: "\\"), UInt8(ascii: "\\")]
            case 0x08: bytes += [UInt8(ascii: "\\"), UInt8(ascii: "b")]
            case 0x0C: bytes += [UInt8(ascii: "\\"), UInt8(ascii: "f")]
            case 0x0A: bytes += [UInt8(ascii: "\\"), UInt8(ascii: "n")]
            case 0x0D: bytes += [UInt8(ascii: "\\"), UInt8(ascii: "r")]
            case 0x09: bytes += [UInt8(ascii: "\\"), UInt8(ascii: "t")]
            case 0x00..<0x20:
                bytes += Array("\\u00".utf8) + [hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
            default: bytes.append(byte)
            }
        }
        bytes.append(UInt8(ascii: "\""))
    }
}
