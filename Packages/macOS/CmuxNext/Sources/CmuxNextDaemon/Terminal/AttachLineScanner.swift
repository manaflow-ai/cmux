import Foundation

/// A one-pass reader for the top level of a daemon attach line, so the hot event (`output`, one per pty chunk)
/// is not parsed as a whole JSON tree twice (once for the route envelope, once for the event) and base64-decoded
/// through a `String`. It reads only what a plain `output` line carries; any line it does not fully understand
/// (a `colors` field, an escaped string, a duplicate key, a value of an unexpected type) returns nil and goes
/// through the general decoder, so what a line means never depends on this scanner.
struct AttachLineScanner {
    /// What the scanner pulled out of a line.
    struct Fields {
        var event: String?
        /// Whether the line carries a `type` key (a v2 stream line): the envelope decoder owns those.
        var hasType = false
        var surface: UInt64?
        var generation: UInt64?
        var data: Data?
    }

    /// The fields of a top-level object line that is an event with plain `data`/`surface`/`generation`,
    /// or nil when the line needs the general decoder. `decodeData: false` (the route envelope) skips `data`
    /// without decoding it.
    static func scanOutput(_ line: Data, decodeData: Bool = true) -> Fields? {
        line.withUnsafeBytes { raw -> Fields? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return scan(Bytes(base: base, count: raw.count), decodeData: decodeData)
        }
    }

    /// Bounds-checked byte access: past either end reads 0, which no structural character or string byte is.
    private struct Bytes {
        let base: UnsafePointer<UInt8>
        let count: Int
        func at(_ index: Int) -> UInt8 { index >= 0 && index < count ? base.advanced(by: index).pointee : 0 }
        func equals(_ range: Range<Int>, _ name: StaticString) -> Bool {
            guard range.count == name.utf8CodeUnitCount, range.lowerBound >= 0, range.upperBound <= count else { return false }
            return memcmp(base.advanced(by: range.lowerBound), name.utf8Start, range.count) == 0
        }
    }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")
    private static let comma = UInt8(ascii: ",")
    private static let colon = UInt8(ascii: ":")

    private static func scan(_ b: Bytes, decodeData: Bool) -> Fields? {
        var i = 0
        let n = b.count
        func skipSpace() {
            while i < n {
                let c = b.at(i)
                guard c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 else { return }
                i += 1
            }
        }
        /// A string with no escapes: its byte range (without quotes), leaving `i` after the closing quote.
        func plainString() -> Range<Int>? {
            guard b.at(i) == quote else { return nil }
            let start = i + 1
            var j = start
            while j < n {
                let c = b.at(j)
                if c == quote { i = j + 1; return start..<j }
                if c == backslash || c < 0x20 { return nil }
                j += 1
            }
            return nil
        }
        func unsigned() -> UInt64? {
            var value: UInt64 = 0
            var digits = 0
            while i < n, b.at(i) >= 0x30, b.at(i) <= 0x39 {
                let (m, o1) = value.multipliedReportingOverflow(by: 10)
                let (s, o2) = m.addingReportingOverflow(UInt64(truncatingIfNeeded: b.at(i) &- 0x30))
                if o1 || o2 { return nil }
                value = s
                digits += 1
                i += 1
            }
            let end = b.at(i)
            guard digits > 0, i < n, end == comma || end == closeBrace || end == 0x20 else { return nil }
            return value
        }
        /// Skips one value we do not read (a string, number, literal, array or object).
        func skipValue() -> Bool {
            guard i < n else { return false }
            switch b.at(i) {
            case quote:
                while i + 1 < n {
                    i += 1
                    if b.at(i) == backslash { i += 1 } else if b.at(i) == quote { i += 1; return true }
                }
                return false
            case openBrace, openBracket:
                var depth = 0
                while i < n {
                    let c = b.at(i)
                    if c == quote {
                        guard skipValue() else { return false }
                        continue
                    }
                    if c == openBrace || c == openBracket { depth += 1 }
                    if c == closeBrace || c == closeBracket {
                        depth -= 1
                        if depth == 0 { i += 1; return true }
                    }
                    i += 1
                }
                return false
            default:
                while i < n, b.at(i) != comma, b.at(i) != closeBrace { i += 1 }
                return i < n
            }
        }

        skipSpace()
        guard b.at(i) == openBrace else { return nil }
        i += 1
        var fields = Fields()
        var seen: UInt8 = 0  // bit per read key, a repeat is refused
        func mark(_ bit: UInt8) -> Bool { defer { seen |= bit }; return seen & bit == 0 }
        var closed = false
        while i < n {
            skipSpace()
            if b.at(i) == closeBrace { i += 1; closed = true; break }
            guard let name = plainString() else { return nil }
            skipSpace()
            guard b.at(i) == colon else { return nil }
            i += 1
            skipSpace()
            if b.equals(name, "data") {
                guard mark(1) else { return nil }
                if decodeData {
                    guard let r = plainString(), let decoded = decodeBase64(b, r) else { return nil }
                    fields.data = decoded
                } else {
                    guard skipValue() else { return nil }
                }
            } else if b.equals(name, "event") {
                guard mark(2), let r = plainString() else { return nil }
                fields.event = String(decoding: UnsafeBufferPointer(start: b.base.advanced(by: r.lowerBound), count: r.count),
                                      as: UTF8.self)
            } else if b.equals(name, "surface") {
                guard mark(4), let v = unsigned() else { return nil }
                fields.surface = v
            } else if b.equals(name, "generation") {
                guard mark(8), let v = unsigned() else { return nil }
                fields.generation = v
            } else if b.equals(name, "type") {
                fields.hasType = true
                guard skipValue() else { return nil }
            } else if b.equals(name, "colors") {
                return nil  // Rare, and decoded by the general path.
            } else {
                guard skipValue() else { return nil }
            }
            skipSpace()
            guard i < n else { return nil }
            if b.at(i) == comma { i += 1; continue }
            if b.at(i) == closeBrace { i += 1; closed = true; break }
            return nil
        }
        skipSpace()
        return closed && i == n ? fields : nil
    }

    private static let invalid: UInt8 = 0xFF

    private static func sextet(_ c: UInt8) -> UInt8 {
        switch c {
        case 65...90: return c &- 65
        case 97...122: return c &- 71
        case 48...57: return c &+ 4
        case 43: return 62
        case 47: return 63
        default: return invalid
        }
    }

    /// Standard padded base64 straight from the line's bytes (no `String`); nil for anything else.
    private static func decodeBase64(_ b: Bytes, _ r: Range<Int>) -> Data? {
        let count = r.count
        if count == 0 { return Data() }
        guard count % 4 == 0 else { return nil }
        let equals = UInt8(ascii: "=")
        var pad = 0
        if b.at(r.upperBound - 1) == equals { pad = 1 }
        if pad == 1, b.at(r.upperBound - 2) == equals { pad = 2 }
        let outCount = count / 4 * 3 - pad
        var out = Data(count: outCount)
        let ok: Bool = out.withUnsafeMutableBytes { dst -> Bool in
            var o = 0
            var p = r.lowerBound
            while p < r.upperBound {
                let last = p + 4 == r.upperBound
                let c2 = b.at(p + 2), c3 = b.at(p + 3)
                let q0 = sextet(b.at(p)), q1 = sextet(b.at(p + 1))
                let q2 = (last && pad == 2) ? 0 : sextet(c2)
                let q3 = (last && pad >= 1) ? 0 : sextet(c3)
                if q0 == invalid || q1 == invalid || q2 == invalid || q3 == invalid { return false }
                if last && pad == 2 && (c2 != equals || c3 != equals) { return false }
                if last && pad == 1 && c3 != equals { return false }
                let v = UInt32(truncatingIfNeeded: q0) << 18 | UInt32(truncatingIfNeeded: q1) << 12 | UInt32(truncatingIfNeeded: q2) << 6 | UInt32(truncatingIfNeeded: q3)
                guard o < dst.count else { return false }
                dst.storeBytes(of: UInt8(truncatingIfNeeded: v >> 16), toByteOffset: o, as: UInt8.self); o += 1
                if !(last && pad == 2) {
                    guard o < dst.count else { return false }
                    dst.storeBytes(of: UInt8(truncatingIfNeeded: v >> 8), toByteOffset: o, as: UInt8.self); o += 1
                }
                if !(last && pad >= 1) {
                    guard o < dst.count else { return false }
                    dst.storeBytes(of: UInt8(truncatingIfNeeded: v), toByteOffset: o, as: UInt8.self); o += 1
                }
                p += 4
            }
            return o == outCount
        }
        return ok ? out : nil
    }
}
