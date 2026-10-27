import Foundation

/// The routing fields of one line (``LineTransport/Envelope``'s `id`, `ok`, `event`, `type`, `stream_id` and
/// `cause`), read from its bytes, so a reply or an event is parsed once: by the code that reads its body. Mojo
/// routes a message by its header and leaves the payload to the receiving stub
/// (mojo/public/cpp/bindings/lib/message.cc, `Message::name()` and `Message::request_id()`); a JSON line has no
/// header, so the scan walks the top-level object and checks the JSON grammar of every value it skips.
///
/// The scan gives up (nil, and the reader decodes an ``LineTransport/Envelope``) wherever it could read the
/// line differently from the decoder: a line that is not one JSON object, a key or a routing string with an
/// escape, a routing key that comes twice, an `id` number that is not a plain non-negative integer, an escaped
/// UTF-16 surrogate, or nesting deeper than ``maxDepth``. The line is valid UTF-8: the reader checked it.
struct LineRouteScan: Equatable {
    var id: UInt64?
    var ok: Bool?
    var event: String?
    var type: String?
    var streamID: String?
    var cause: String?
    /// An event's `flow`: the key press an `output` event echoes (p09-observability-018), read so the reader
    /// marks the echo's handoff before it decodes the line (p09-observability-102). Nil without one, or for a
    /// value that is not a plain non-negative integer (the decoder reads that one).
    var flow: UInt64?

    /// Containers deeper than this are left to the decoder, so the scan's recursion stays shallow.
    static let maxDepth = 64

    private init() {}

    init?<Line: RandomAccessCollection<UInt8>>(_ line: Line) where Line.Index == Int {
        var scanner = Scanner(bytes: line)
        guard let scanned = scanner.topLevelObject() else { return nil }
        self = scanned
    }

    /// The routing fields as an envelope with no error fields: a reply that is not `ok:true` is
    /// decoded whole for those.
    var envelope: LineTransport.Envelope {
        LineTransport.Envelope(id: id, ok: ok, event: event, type: type, streamID: streamID, cause: cause)
    }

    private enum Field: UInt8 {
        case id = 1, ok = 2, event = 4, type = 8, streamID = 16, cause = 32, flow = 64

        init?(key: some Sequence<UInt8>) {
            if key.elementsEqual(Byte.idKey) {
                self = .id
            } else if key.elementsEqual(Byte.okKey) {
                self = .ok
            } else if key.elementsEqual(Byte.eventKey) {
                self = .event
            } else if key.elementsEqual(Byte.typeKey) {
                self = .type
            } else if key.elementsEqual(Byte.streamIDKey) {
                self = .streamID
            } else if key.elementsEqual(Byte.causeKey) {
                self = .cause
            } else if key.elementsEqual(Byte.flowKey) {
                self = .flow
            } else {
                return nil
            }
        }
    }

    /// One pass over a line; `index` only moves forward, and every read is checked.
    private struct Scanner<Line: RandomAccessCollection<UInt8>> where Line.Index == Int {
        let bytes: Line
        var index: Int

        init(bytes: Line) {
            self.bytes = bytes
            index = bytes.startIndex
        }

        private var current: UInt8? { bytes[checked: index] }

        mutating func topLevelObject() -> LineRouteScan? {
            var fields = LineRouteScan()
            var seen: UInt8 = 0
            skipSpace()
            let complete = object { scanner -> Bool in
                guard let key = scanner.plainString() else { return false }
                scanner.skipSpace()
                guard scanner.take(Byte.colon) else { return false }
                scanner.skipSpace()
                guard let field = Field(key: scanner.slice(key)) else { return scanner.skipValue(depth: 1) }
                guard seen & field.rawValue == 0 else { return false }
                seen |= field.rawValue
                return scanner.read(field, into: &fields)
            }
            skipSpace()
            guard complete, index == bytes.endIndex else { return nil }
            if fields.event == nil {
                fields.cause = nil
                fields.flow = nil
            }
            return fields
        }

        /// The bytes of `range`, a range this scan read.
        private func slice(_ range: Range<Int>) -> Line.SubSequence {
            bytes.suffix(from: range.lowerBound).prefix(range.count)
        }

        /// An object at `index`: `{`, then members `member` reads (from its key's quote) separated by commas, then `}`.
        private mutating func object(_ member: (inout Self) -> Bool) -> Bool {
            guard take(Byte.openBrace) else { return false }
            skipSpace()
            if take(Byte.closeBrace) { return true }
            guard member(&self) else { return false }
            skipSpace()
            while take(Byte.comma) {
                skipSpace()
                guard member(&self) else { return false }
                skipSpace()
            }
            return take(Byte.closeBrace)
        }

        /// An array at `index`: `[`, values separated by commas, `]`.
        private mutating func array(depth: Int) -> Bool {
            guard take(Byte.openBracket) else { return false }
            skipSpace()
            if take(Byte.closeBracket) { return true }
            guard skipValue(depth: depth) else { return false }
            skipSpace()
            while take(Byte.comma) {
                skipSpace()
                guard skipValue(depth: depth) else { return false }
                skipSpace()
            }
            return take(Byte.closeBracket)
        }

        /// Reads one routing value as ``LineTransport/Envelope`` decodes it; false gives the line up.
        private mutating func read(_ field: Field, into fields: inout LineRouteScan) -> Bool {
            guard let first = current else { return false }
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
                let digits = slice(start..<index)
                // A sign, a fraction or an exponent: the decoder's integer rules decide, not the scan's.
                guard digits.allSatisfy(Byte.isDigit) else { return false }
                fields.id = UInt64(String(decoding: digits, as: UTF8.self), radix: 10)
                return true
            case .ok:
                if literal(Byte.trueWord) {
                    fields.ok = true
                    return true
                }
                if literal(Byte.falseWord) {
                    fields.ok = false
                    return true
                }
                return skipValue(depth: 1)
            case .flow:
                guard Byte.isDigit(first) else { return skipValue(depth: 1) }
                let start = index
                guard skipNumber() else { return false }
                fields.flow = Self.plainInteger(slice(start..<index))
                return true
            case .event, .type, .streamID, .cause:
                guard first == Byte.quote else { return skipValue(depth: 1) }
                guard let text = plainText() else { return false }
                switch field {
                case .event: fields.event = text
                case .type: fields.type = text
                case .streamID: fields.streamID = text
                case .cause: fields.cause = text
                case .id, .ok, .flow: break  // read above
                }
                return true
            }
        }

        /// `digits` as a UInt64, read in place (a flow has up to 20 digits, past a small string's 15 bytes);
        /// nil for a fraction, an exponent or an overflow.
        private static func plainInteger(_ digits: Line.SubSequence) -> UInt64? {
            var value: UInt64 = 0
            for digit in digits {
                guard Byte.isDigit(digit) else { return nil }
                let (times10, over1) = value.multipliedReportingOverflow(by: 10)
                let (sum, over2) = times10.addingReportingOverflow(UInt64(truncatingIfNeeded: digit &- UInt8(ascii: "0")))
                guard !over1, !over2 else { return nil }
                value = sum
            }
            return value
        }

        /// A string with no escape and no control byte, as text; nil otherwise.
        private mutating func plainText() -> String? {
            guard let range = plainString() else { return nil }
            return String(bytes: slice(range), encoding: .utf8)
        }

        /// The content range of a string with no escape and no control byte; nil otherwise.
        private mutating func plainString() -> Range<Int>? {
            guard take(Byte.quote) else { return nil }
            let start = index
            guard let end = bytes.suffix(from: index).firstIndex(where: Byte.endsPlainString),
                  bytes[checked: end] == Byte.quote else { return nil }
            index = end + 1
            return start..<end
        }

        private mutating func skipValue(depth: Int) -> Bool {
            guard let first = current, depth <= LineRouteScan.maxDepth else { return false }
            switch first {
            case Byte.quote: return skipString()
            case Byte.openBrace:
                return object { scanner in
                    guard scanner.current == Byte.quote, scanner.skipString() else { return false }
                    scanner.skipSpace()
                    guard scanner.take(Byte.colon) else { return false }
                    scanner.skipSpace()
                    return scanner.skipValue(depth: depth + 1)
                }
            case Byte.openBracket: return array(depth: depth + 1)
            case UInt8(ascii: "t"): return literal(Byte.trueWord)
            case UInt8(ascii: "f"): return literal(Byte.falseWord)
            case UInt8(ascii: "n"): return literal(Byte.nullWord)
            default: return skipNumber()
            }
        }

        /// Skips a string at `index`. An escape of a UTF-16 surrogate gives the line up: the decoder's
        /// pairing rules decide those.
        private mutating func skipString() -> Bool {
            guard take(Byte.quote) else { return false }
            while let stop = bytes.suffix(from: index).firstIndex(where: Byte.endsPlainString), let byte = bytes[checked: stop] {
                index = stop + 1
                if byte == Byte.quote { return true }
                guard byte == Byte.backslash, skipEscape() else { return false }
            }
            return false
        }

        /// The rest of an escape whose backslash is behind `index`.
        private mutating func skipEscape() -> Bool {
            guard let kind = current else { return false }
            index += 1
            guard kind == UInt8(ascii: "u") else { return Byte.simpleEscapes.contains(kind) }
            var scalar: UInt32 = 0
            for _ in 0..<4 {
                guard let hex = current, let digit = Byte.hexValue(hex) else { return false }
                scalar = scalar << 4 | digit
                index += 1
            }
            return !(0xD800...0xDFFF).contains(scalar)
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
            while let byte = current, Byte.isDigit(byte) { index += 1 }
            return index > start
        }

        private mutating func literal(_ word: [UInt8]) -> Bool {
            guard bytes.suffix(from: index).starts(with: word) else { return false }
            index += word.count
            return true
        }

        mutating func skipSpace() {
            while let byte = current, Byte.isSpace(byte) { index += 1 }
        }

        mutating func take(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
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
        static let trueWord = Array("true".utf8)
        static let falseWord = Array("false".utf8)
        static let nullWord = Array("null".utf8)
        static let idKey = Array("id".utf8)
        static let okKey = Array("ok".utf8)
        static let eventKey = Array("event".utf8)
        static let typeKey = Array("type".utf8)
        static let streamIDKey = Array("stream_id".utf8)
        static let causeKey = Array("cause".utf8)
        static let flowKey = Array("flow".utf8)
        /// The one-letter escapes after a backslash: `"`, `\`, `/`, `b`, `f`, `n`, `r`, `t`.
        static let simpleEscapes: Set<UInt8> = Set("\"\\/bfnrt".utf8)

        static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        static func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        /// A byte a plain string's scan stops at: its closing quote, an escape, or a control byte.
        static func endsPlainString(_ byte: UInt8) -> Bool {
            byte == quote || byte == backslash || byte < 0x20
        }

        static func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(truncatingIfNeeded: byte &- UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(truncatingIfNeeded: byte &- UInt8(ascii: "a") &+ 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(truncatingIfNeeded: byte &- UInt8(ascii: "A") &+ 10)
            default: nil
            }
        }
    }
}
