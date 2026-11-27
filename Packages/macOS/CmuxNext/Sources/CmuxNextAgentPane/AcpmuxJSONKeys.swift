/// A strict duplicate-key check for page frames (ad349, round 7). It only refuses: the frame the
/// relay sends is Foundation's parse of the same bytes, serialized again. Foundation keeps one of
/// two duplicate keys without an error, and the daemon's serde_json keeps the last, so a frame with
/// a duplicate could be checked as one value and acted on as the other.
///
/// It reads the whole JSON grammar (RFC 8259: strings, escapes, UTF-8, numbers, literals), without
/// recursion, so nesting depth costs only memory. Keys are decoded and compared as Swift strings,
/// which also catches canonically equal keys (a composed and a decomposed accent), which Swift's
/// dictionaries hold as one key.
nonisolated enum AcpmuxJSONKeys {
    /// True when `bytes` is not one well-formed JSON text, or when one object holds two keys that
    /// decode to equal strings.
    static func refuses(_ bytes: [UInt8]) -> Bool { verdict(bytes) != .clean }

    nonisolated enum Verdict: Equatable { case clean, malformed, duplicate }

    static func verdict(_ bytes: [UInt8]) -> Verdict {
        bytes.withUnsafeBufferPointer { verdict($0) }
    }

    /// The page frame's own UTF-8, read in place.
    static func verdict(_ text: String) -> Verdict {
        var text = text
        return text.withUTF8 { verdict($0) }
    }

    static func verdict(_ buffer: UnsafeBufferPointer<UInt8>) -> Verdict {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return .malformed }
        var reader = Reader(bytes: base, count: buffer.count)
        let wellFormed = reader.wellFormedWithoutDuplicates()
        return reader.duplicate ? .duplicate : wellFormed ? .clean : .malformed
    }

    private nonisolated enum Expect { case value, valueOrEnd, key, keyOrEnd, commaOrEnd }

    private nonisolated struct Reader {
        /// The frame's bytes, `count` of them (read only while the caller holds the buffer).
        let bytes: UnsafePointer<UInt8>
        let count: Int
        var i = 0
        /// The open containers: an object's keys so far, or nil for an array.
        var stack: [Set<String>?] = []
        /// Set when the read stopped at a repeated key.
        var duplicate = false

        init(bytes: UnsafePointer<UInt8>, count: Int) {
            self.bytes = bytes
            self.count = count
        }

        /// Whether the 8 bytes at `at` may hold a quote, a backslash, a control byte or a byte of
        /// a multi-byte sequence. A false alarm only sends the word to the byte path.
        @inline(__always) func special(_ at: Int) -> Bool {
            let w = UnsafeRawPointer(bytes + at).loadUnaligned(as: UInt64.self)
            let high: UInt64 = 0x8080_8080_8080_8080
            let ones: UInt64 = 0x0101_0101_0101_0101
            let control = (w &- 0x2020_2020_2020_2020) & ~w & high
            let q = w ^ 0x2222_2222_2222_2222
            let b = w ^ 0x5C5C_5C5C_5C5C_5C5C
            return (w & high) | control | ((q &- ones) & ~q & high) | ((b &- ones) & ~b & high) != 0
        }

        mutating func wellFormedWithoutDuplicates() -> Bool {
            var expect = Expect.value
            space()
            // Every step reads at least one byte or returns.
            while i < count {
                switch expect {
                case .value, .valueOrEnd:
                    if expect == .valueOrEnd, bytes[i] == 0x5D {
                        i += 1
                        stack.removeLast()
                        expect = .commaOrEnd
                    } else {
                        switch bytes[i] {
                        case 0x7B: stack.append(Set<String>()); i += 1; expect = .keyOrEnd
                        case 0x5B: stack.append(nil); i += 1; expect = .valueOrEnd
                        case 0x22: guard string(decode: false) != nil else { return false }; expect = .commaOrEnd
                        case 0x74, 0x66, 0x6E: guard literal() else { return false }; expect = .commaOrEnd
                        case 0x2D, 0x30...0x39: guard number() else { return false }; expect = .commaOrEnd
                        default: return false
                        }
                    }
                case .key, .keyOrEnd:
                    if expect == .keyOrEnd, bytes[i] == 0x7D {
                        i += 1
                        stack.removeLast()
                        expect = .commaOrEnd
                    } else {
                        guard bytes[i] == 0x22, let key = string(decode: true) else { return false }
                        guard stack[stack.count - 1]?.insert(key).inserted == true else { duplicate = true; return false }
                        space()
                        guard i < count, bytes[i] == 0x3A else { return false }
                        i += 1
                        expect = .value
                    }
                case .commaOrEnd:
                    guard let top = stack.last else { return false }
                    switch (bytes[i], top == nil) {
                    case (0x2C, false): expect = .key
                    case (0x2C, true): expect = .value
                    case (0x7D, false), (0x5D, true): stack.removeLast(); expect = .commaOrEnd
                    default: return false
                    }
                    i += 1
                }
                space()
            }
            return expect == .commaOrEnd && stack.isEmpty
        }

        mutating func space() {
            while i < count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        }

        mutating func literal() -> Bool {
            for word in ["true", "false", "null"] {
                let w = Array(word.utf8)
                if i + w.count <= count, (0..<w.count).allSatisfy({ bytes[i + $0] == w[$0] }) { i += w.count; return true }
            }
            return false
        }

        mutating func digits() -> Bool {
            let start = i
            while i < count, (0x30...0x39).contains(bytes[i]) { i += 1 }
            return i > start
        }

        mutating func number() -> Bool {
            if bytes[i] == 0x2D { i += 1 }
            guard i < count else { return false }
            if bytes[i] == 0x30 { i += 1 } else if (0x31...0x39).contains(bytes[i]) { _ = digits() } else { return false }
            if i < count, bytes[i] == 0x2E { i += 1; guard digits() else { return false } }
            if i < count, bytes[i] == 0x65 || bytes[i] == 0x45 {
                i += 1
                if i < count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
                guard digits() else { return false }
            }
            return true
        }

        func hex4(_ at: Int) -> UInt32? {
            guard at + 4 <= count else { return nil }
            var value: UInt32 = 0
            for byte in UnsafeBufferPointer(start: bytes + at, count: 4) {
                let digit: UInt32
                switch byte {
                case 0x30...0x39: digit = UInt32(byte - 0x30)
                case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
                case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
                default: return nil
                }
                value = value << 4 | digit
            }
            return value
        }

        /// The length of the well-formed UTF-8 sequence at `i`, or nil.
        func sequence() -> Int? {
            let lead = bytes[i]
            let (length, second): (Int, ClosedRange<UInt8>) = switch lead {
            case 0x00...0x7F: (1, 0x80...0xBF)
            case 0xC2...0xDF: (2, 0x80...0xBF)
            case 0xE0: (3, 0xA0...0xBF)
            case 0xE1...0xEC, 0xEE...0xEF: (3, 0x80...0xBF)
            case 0xED: (3, 0x80...0x9F)
            case 0xF0: (4, 0x90...0xBF)
            case 0xF1...0xF3: (4, 0x80...0xBF)
            case 0xF4: (4, 0x80...0x8F)
            default: (0, 0x80...0xBF)
            }
            guard length > 0, i + length <= count else { return nil }
            guard length == 1 || second.contains(bytes[i + 1]) else { return nil }
            for k in 2..<max(length, 2) where !(0x80...0xBF).contains(bytes[i + k]) { return nil }
            return length
        }

        /// The string at `i` (a quote): its decoded text when `decode`, else "". Nil when malformed.
        mutating func string(decode: Bool) -> String? {
            i += 1
            var out: [UInt8] = []
            while i < count {
                // A value's plain ASCII runs, 8 bytes at a time (a key is decoded byte by byte).
                if !decode {
                    while i + 8 <= count, !special(i) { i += 8 }
                    guard i < count else { return nil }
                }
                let byte = bytes[i]
                if byte == 0x22 {
                    i += 1
                    return decode ? String(decoding: out, as: UTF8.self) : ""
                }
                if byte < 0x20 { return nil }
                if byte == 0x5C {
                    guard i + 1 < count else { return nil }
                    let escaped: UInt8
                    switch bytes[i + 1] {
                    case 0x22, 0x5C, 0x2F: escaped = bytes[i + 1]
                    case 0x62: escaped = 0x08
                    case 0x66: escaped = 0x0C
                    case 0x6E: escaped = 0x0A
                    case 0x72: escaped = 0x0D
                    case 0x74: escaped = 0x09
                    case 0x75:
                        guard var scalar = hex4(i + 2) else { return nil }
                        i += 6
                        if (0xD800...0xDBFF).contains(scalar) {
                            guard i + 1 < count, bytes[i] == 0x5C, bytes[i + 1] == 0x75, let low = hex4(i + 2),
                                  (0xDC00...0xDFFF).contains(low) else { return nil }
                            i += 6
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(scalar) {
                            return nil
                        }
                        guard let unicode = Unicode.Scalar(scalar) else { return nil }
                        if decode { out.append(contentsOf: String(Character(unicode)).utf8) }
                        continue
                    default: return nil
                    }
                    if decode { out.append(escaped) }
                    i += 2
                    continue
                }
                guard let length = sequence() else { return nil }
                if decode { out.append(contentsOf: UnsafeBufferPointer(start: bytes + i, count: length)) }
                i += length
            }
            return nil
        }
    }
}
