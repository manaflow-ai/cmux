import Foundation

/// Reads a daemon event line's top-level `"event"` name from its bytes, without a JSON parse, so
/// the line is decoded once, straight into its event's type (p05-ipc.md task 022). Mojo reads a
/// message's name from its fixed header before it deserializes the payload the same way
/// (mojo/public/cpp/bindings/lib/message.cc, `Message::name()`).
///
/// It walks only the top-level object: nested objects, arrays and strings are skipped with their
/// escapes, so an `"event"` key inside a field never matches. It returns nil, and the caller does
/// a full parse instead, when the line is not a JSON object, has no top-level `"event"` key, or
/// the key or the name holds an escape (serde_json writes neither for a schema name).
struct WireEventNameScanner {
    private let bytes: UnsafeRawBufferPointer
    private var index = 0

    private init(bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    /// The top-level `"event"` string of `line`, or nil when the scan cannot read it.
    static func name(in line: Data) -> String? {
        line.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> String? in
            var scanner = WireEventNameScanner(bytes: bytes)
            return scanner.topLevelEventName()
        }
    }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let colon = UInt8(ascii: ":")
    private static let comma = UInt8(ascii: ",")
    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")
    private static let eventKey = Array("event".utf8)

    private mutating func topLevelEventName() -> String? {
        skipSpace()
        guard take(Self.openBrace) else { return nil }
        skipSpace()
        while let key = plainString() {
            skipSpace()
            guard take(Self.colon) else { return nil }
            skipSpace()
            if bytes[key].elementsEqual(Self.eventKey) {
                guard let value = plainString() else { return nil }
                return String(bytes: bytes[value], encoding: .utf8)
            }
            guard skipValue() else { return nil }
            skipSpace()
            guard take(Self.comma) else { return nil }
            skipSpace()
        }
        return nil
    }

    /// The content range of a string with no escape and no control byte; nil otherwise.
    private mutating func plainString() -> Range<Int>? {
        guard take(Self.quote) else { return nil }
        let start = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == Self.quote {
                index += 1
                return start..<(index - 1)
            }
            if byte == Self.backslash || byte < 0x20 { return nil }
            index += 1
        }
        return nil
    }

    private mutating func skipValue() -> Bool {
        guard index < bytes.count else { return false }
        switch bytes[index] {
        case Self.quote:
            return skipString()
        case Self.openBrace, Self.openBracket:
            return skipContainer()
        default:
            // A number, `true`, `false` or `null`: up to the next delimiter.
            let start = index
            while index < bytes.count, !Self.endsScalar(bytes[index]) { index += 1 }
            return index > start
        }
    }

    /// Skips a string at `index`, escapes included.
    private mutating func skipString() -> Bool {
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == Self.backslash {
                index += 2
                continue
            }
            index += 1
            if byte == Self.quote { return true }
        }
        return false
    }

    /// Skips an object or array at `index` with everything it holds.
    private mutating func skipContainer() -> Bool {
        var depth = 0
        while index < bytes.count {
            switch bytes[index] {
            case Self.quote:
                guard skipString() else { return false }
                continue
            case Self.openBrace, Self.openBracket:
                depth += 1
            case Self.closeBrace, Self.closeBracket:
                depth -= 1
                if depth == 0 {
                    index += 1
                    return true
                }
            default:
                break
            }
            index += 1
        }
        return false
    }

    private mutating func skipSpace() {
        while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func endsScalar(_ byte: UInt8) -> Bool {
        byte == comma || byte == closeBrace || byte == closeBracket || isSpace(byte)
    }
}
