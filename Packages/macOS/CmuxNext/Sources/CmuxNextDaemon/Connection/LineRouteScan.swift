import Foundation

/// The routing fields of one line (``LineTransport/Envelope``'s `id`, `ok`, `event`, `type`, `stream_id` and `cause`),
/// read from its bytes, so a reply or an event is parsed once: by the code that reads its body. Mojo routes
/// a message by its header and leaves the payload to the receiving stub (mojo/public/cpp/bindings/lib/message.cc,
/// `Message::name()` and `Message::request_id()`); a JSON line has no header, so the scan walks the
/// top-level object and checks the JSON grammar of every value it skips.
///
/// The scan gives up (nil, and the reader decodes an ``LineTransport/Envelope``) wherever it could read the line
/// differently from the decoder: a line that is not one JSON object, a key or a routing string with an
/// escape, a routing key that comes twice, an `id` number that is not a plain non-negative integer, or
/// nesting deeper than ``maxDepth``. The line is valid UTF-8: the reader checked it.
struct LineRouteScan: Equatable {
    var id: UInt64?
    var ok: Bool?
    var event: String?
    var type: String?
    var streamID: String?
    var cause: String?

    /// Containers deeper than this are left to the decoder, so the scan's recursion stays shallow.
    static let maxDepth = 64

    private init() {}

    init?(_ line: Data) {
        let scanned = line.withUnsafeBytes { bytes -> LineRouteScan? in
            var scanner = Scanner(bytes: bytes)
            return scanner.topLevelObject()
        }
        guard let scanned else { return nil }
        self = scanned
    }

    /// The routing fields as an envelope with no error fields: a reply that is not `ok:true` is
    /// decoded whole for those.
    var envelope: LineTransport.Envelope {
        LineTransport.Envelope(id: id, ok: ok, event: event, type: type, streamID: streamID, cause: cause)
    }

    private enum Field: UInt8 {
        case id = 1, ok = 2, event = 4, type = 8, streamID = 16, cause = 32
    }

    private struct Scanner {
        let bytes: UnsafeRawBufferPointer
        var index = 0

        init(bytes: UnsafeRawBufferPointer) {
            self.bytes = bytes
        }

        mutating func topLevelObject() -> LineRouteScan? {
            var fields = LineRouteScan()
            var seen: UInt8 = 0
            skipSpace()
            guard take(Byte.openBrace) else { return nil }
            skipSpace()
            if !take(Byte.closeBrace) {
                repeat {
                    skipSpace()
                    guard let key = plainString() else { return nil }
                    skipSpace()
                    guard take(Byte.colon) else { return nil }
                    skipSpace()
                    if let field = Self.field(bytes[key]) {
                        guard seen & field.rawValue == 0 else { return nil }
                        seen |= field.rawValue
                        guard read(field, into: &fields) else { return nil }
                    } else {
                        guard skipValue(depth: 1) else { return nil }
                    }
                    skipSpace()
                } while take(Byte.comma)
                guard take(Byte.closeBrace) else { return nil }
            }
            skipSpace()
            guard index == bytes.count else { return nil }
            if fields.event == nil { fields.cause = nil }
            return fields
        }

        private static func field(_ key: Slice<UnsafeRawBufferPointer>) -> Field? {
            if key.elementsEqual("id".utf8) { return .id }
            if key.elementsEqual("ok".utf8) { return .ok }
            if key.elementsEqual("event".utf8) { return .event }
            if key.elementsEqual("type".utf8) { return .type }
            if key.elementsEqual("stream_id".utf8) { return .streamID }
            if key.elementsEqual("cause".utf8) { return .cause }
            return nil
        }

        /// Reads one routing value as ``LineTransport/Envelope`` decodes it; false gives the line up.
        private mutating func read(_ field: Field, into fields: inout LineRouteScan) -> Bool {
            guard index < bytes.count else { return false }
            let first = bytes[index]
            switch field {
            case .id:
                if first == Byte.quote {
                    guard let text = plainText() else { return false }
                    fields.id = UInt64(text, radix: 10)
                    return true
                }
                guard first == Byte.minus || Byte.isDigit(first) else { return skipValue(depth: 1) }
                let start = index
                guard skipNumber() else { return false }
                // A sign, a fraction or an exponent: the decoder's integer rules decide, not the scan's.
                guard bytes[start..<index].allSatisfy(Byte.isDigit) else { return false }
                fields.id = UInt64(String(decoding: bytes[start..<index], as: UTF8.self), radix: 10)
                return true
            case .ok:
                if literal("true") { fields.ok = true; return true }
                if literal("false") { fields.ok = false; return true }
                return skipValue(depth: 1)
            case .event, .type, .streamID, .cause:
                guard first == Byte.quote else { return skipValue(depth: 1) }
                guard let text = plainText() else { return false }
                switch field {
                case .event: fields.event = text
                case .type: fields.type = text
                case .streamID: fields.streamID = text
                default: fields.cause = text
                }
                return true
            }
        }

        /// A string with no escape and no control byte, as text; nil otherwise.
        private mutating func plainText() -> String? {
            guard let range = plainString() else { return nil }
            return String(bytes: bytes[range], encoding: .utf8)
        }

        /// The content range of a string with no escape and no control byte; nil otherwise.
        private mutating func plainString() -> Range<Int>? {
            guard take(Byte.quote) else { return nil }
            let start = index
            while index < bytes.count {
                let byte = bytes[index]
                if byte == Byte.quote {
                    index += 1
                    return start..<(index - 1)
                }
                if byte == Byte.backslash || byte < 0x20 { return nil }
                index += 1
            }
            return nil
        }

        private mutating func skipValue(depth: Int) -> Bool {
            guard index < bytes.count, depth <= LineRouteScan.maxDepth else { return false }
            switch bytes[index] {
            case Byte.quote: return skipString()
            case Byte.openBrace: return skipObject(depth: depth + 1)
            case Byte.openBracket: return skipArray(depth: depth + 1)
            case UInt8(ascii: "t"): return literal("true")
            case UInt8(ascii: "f"): return literal("false")
            case UInt8(ascii: "n"): return literal("null")
            default: return skipNumber()
            }
        }

        private mutating func skipObject(depth: Int) -> Bool {
            index += 1
            skipSpace()
            if take(Byte.closeBrace) { return true }
            repeat {
                skipSpace()
                guard index < bytes.count, bytes[index] == Byte.quote, skipString() else { return false }
                skipSpace()
                guard take(Byte.colon) else { return false }
                skipSpace()
                guard skipValue(depth: depth) else { return false }
                skipSpace()
            } while take(Byte.comma)
            return take(Byte.closeBrace)
        }

        private mutating func skipArray(depth: Int) -> Bool {
            index += 1
            skipSpace()
            if take(Byte.closeBracket) { return true }
            repeat {
                skipSpace()
                guard skipValue(depth: depth) else { return false }
                skipSpace()
            } while take(Byte.comma)
            return take(Byte.closeBracket)
        }

        /// Skips a string at `index`. An escape of a UTF-16 surrogate gives the line up: the
        /// decoder's pairing rules decide those.
        private mutating func skipString() -> Bool {
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == Byte.quote {
                    index += 1
                    return true
                }
                if byte < 0x20 { return false }
                guard byte == Byte.backslash else {
                    index += 1
                    continue
                }
                guard index + 1 < bytes.count else { return false }
                switch bytes[index + 1] {
                case Byte.quote, Byte.backslash, UInt8(ascii: "/"), UInt8(ascii: "b"), UInt8(ascii: "f"),
                     UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                    index += 2
                case UInt8(ascii: "u"):
                    guard index + 6 <= bytes.count else { return false }
                    var scalar: UInt32 = 0
                    for hex in bytes[(index + 2)..<(index + 6)] {
                        guard let digit = Byte.hexValue(hex) else { return false }
                        scalar = scalar << 4 | digit
                    }
                    guard !(0xD800...0xDFFF).contains(scalar) else { return false }
                    index += 6
                default:
                    return false
                }
            }
            return false
        }

        /// Skips a number in the JSON grammar: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.
        private mutating func skipNumber() -> Bool {
            _ = take(Byte.minus)
            if !take(UInt8(ascii: "0")) {
                guard skipDigits() else { return false }
            }
            if take(UInt8(ascii: ".")) {
                guard skipDigits() else { return false }
            }
            if take(UInt8(ascii: "e")) || take(UInt8(ascii: "E")) {
                if !take(UInt8(ascii: "+")) { _ = take(Byte.minus) }
                guard skipDigits() else { return false }
            }
            return true
        }

        /// Skips one or more digits; false when there is none.
        private mutating func skipDigits() -> Bool {
            let start = index
            while index < bytes.count, Byte.isDigit(bytes[index]) { index += 1 }
            return index > start
        }

        private mutating func literal(_ word: StaticString) -> Bool {
            let count = word.utf8CodeUnitCount
            guard index + count <= bytes.count else { return false }
            let matches = word.withUTF8Buffer { bytes[index..<(index + count)].elementsEqual($0) }
            guard matches else { return false }
            index += count
            return true
        }

        private mutating func skipSpace() {
            while index < bytes.count, Byte.isSpace(bytes[index]) { index += 1 }
        }

        private mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }

    private enum Byte {
        static let quote = UInt8(ascii: "\"")
        static let backslash = UInt8(ascii: "\\")
        static let colon = UInt8(ascii: ":")
        static let comma = UInt8(ascii: ",")
        static let minus = UInt8(ascii: "-")
        static let openBrace = UInt8(ascii: "{")
        static let closeBrace = UInt8(ascii: "}")
        static let openBracket = UInt8(ascii: "[")
        static let closeBracket = UInt8(ascii: "]")

        static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        static func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        static func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
            default: nil
            }
        }
    }
}
