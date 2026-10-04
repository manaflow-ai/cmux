import Foundation

/// One left-to-right pass over bytes that masks a secret store's values
/// (``BrowserReplSecretStore``).
///
/// The pass never rescans its own output and never builds an intermediate
/// copy: at each position it checks, in order, a Base64 token that starts
/// there, a valid TOTP code standing as a whole number, and each value in
/// any of its encodings, copying unmatched bytes through. The cost is linear
/// in the input for a fixed set of secrets.
///
/// A mask is longer than a short value, so masking can grow the input
/// (a one-character value with a 64-character name grows 73 times). The
/// growth is bounded by a budget the caller passes: a pass that would
/// exceed it stops and reports ``Outcome/overLimit`` instead of allocating
/// more. Adjacent matches of one mask become a single mask.
struct BrowserReplSecretScanner {
    /// A registered value, compiled for matching.
    struct Value {
        let mask: [UInt8]
        let utf8: [UInt8]
        let scalars: [Unicode.Scalar]
        /// Each scalar's UTF-8 bytes.
        let scalarBytes: [[UInt8]]
        /// One of its characters starts an encoded form too (`%`, `\`,
        /// `&`, `+`), so a match also tries reading it literally first.
        let ambiguous: Bool

        init(value: String, mask: String) {
            self.mask = Array(mask.utf8)
            utf8 = Array(value.utf8)
            scalars = Array(value.unicodeScalars)
            scalarBytes = scalars.map { Array(String($0).utf8) }
            ambiguous = scalars.contains { "%\\&+".unicodeScalars.contains($0) }
        }
    }

    enum Outcome: Equatable {
        case unchanged
        case redacted([UInt8])
        case overLimit
    }

    private let values: [Value]
    private let codes: [(digits: [UInt8], mask: [UInt8])]
    /// Bytes at which some value's match can start.
    private let startBytes: [Bool]

    /// - Parameters:
    ///   - values: The values to mask, longest first.
    ///   - codes: TOTP codes to mask where they stand as a whole number.
    init(values: [Value], codes: [(digits: [UInt8], mask: [UInt8])]) {
        self.values = values
        self.codes = codes
        var startBytes = [Bool](repeating: false, count: 256)
        for value in values {
            guard let first = value.utf8.first else { continue }
            startBytes[Int(first)] = true
            for byte in "%\\&".utf8 { startBytes[Int(byte)] = true }
            if value.scalars.first == " " { startBytes[Int(UInt8(ascii: "+"))] = true }
        }
        self.startBytes = startBytes
    }

    var isEmpty: Bool { values.isEmpty && codes.isEmpty }

    /// Masks `input`. `budget` is how many bytes the output may grow past
    /// the input; it is reduced by the growth of this pass.
    func redact(_ input: UnsafeBufferPointer<UInt8>, budget: inout Int) -> Outcome {
        guard !isEmpty, !input.isEmpty else { return .unchanged }
        var pass = Pass(input: input, budget: budget)
        var index = 0
        var tokenCheckedUntil = 0
        var decoded: [UInt8] = []
        while index < input.count {
            let byte = input[index]
            let startsRun = index == 0 || !Self.isBase64[Int(input[index - 1])]
            if Self.isBase64[Int(byte)], startsRun, index >= tokenCheckedUntil {
                var end = index
                while end < input.count, Self.isBase64[Int(input[end])] { end += 1 }
                if let mask = base64Mask(input, from: index, to: end, buffer: &decoded) {
                    var padded = end
                    while padded < input.count, padded - end < 2, input[padded] == UInt8(ascii: "=") { padded += 1 }
                    guard pass.emit(from: index, to: padded, mask: mask) else { return .overLimit }
                    index = padded
                    continue
                }
                tokenCheckedUntil = end
            }
            if !codes.isEmpty, Self.isDigit(byte), index == 0 || !Self.isDigit(input[index - 1]) {
                var end = index
                while end < input.count, Self.isDigit(input[end]) { end += 1 }
                let run = UnsafeBufferPointer(rebasing: input[index..<end])
                if let code = codes.first(where: { $0.digits.elementsEqual(run) }) {
                    guard pass.emit(from: index, to: end, mask: code.mask) else { return .overLimit }
                    index = end
                    continue
                }
            }
            if startBytes[Int(byte)] {
                var best: (end: Int, mask: [UInt8])?
                for value in values {
                    if let end = match(value, in: input, at: index), end > (best?.end ?? index) {
                        best = (end, value.mask)
                    }
                }
                if let best {
                    guard pass.emit(from: index, to: best.end, mask: best.mask) else { return .overLimit }
                    index = best.end
                    continue
                }
            }
            index += 1
        }
        guard let output = pass.finish() else { return .unchanged }
        budget = pass.budget
        return .redacted(output)
    }

    /// The output under construction; nil until the first match.
    private struct Pass {
        let input: UnsafeBufferPointer<UInt8>
        var budget: Int
        var output: [UInt8]?
        var copiedUntil = 0
        var lastEnd = -1
        var lastMask: [UInt8] = []

        init(input: UnsafeBufferPointer<UInt8>, budget: Int) {
            self.input = input
            self.budget = budget
        }

        /// Replaces `input[start..<end]` with `mask`. False when the output
        /// would grow past the budget.
        mutating func emit(from start: Int, to end: Int, mask: [UInt8]) -> Bool {
            if output == nil {
                output = []
                output?.reserveCapacity(input.count)
            }
            output?.append(contentsOf: UnsafeBufferPointer(rebasing: input[copiedUntil..<start]))
            if !(start == lastEnd && mask == lastMask) {
                output?.append(contentsOf: mask)
            }
            copiedUntil = end
            lastEnd = end
            lastMask = mask
            return (output?.count ?? 0) - copiedUntil <= budget
        }

        mutating func finish() -> [UInt8]? {
            guard var output else { return nil }
            output.append(contentsOf: UnsafeBufferPointer(rebasing: input[copiedUntil...]))
            budget -= max(0, output.count - input.count)
            return output
        }
    }

    // MARK: Values

    /// The end of a match of `value` at `start`, in any of its encodings.
    private func match(_ value: Value, in input: UnsafeBufferPointer<UInt8>, at start: Int) -> Int? {
        let count = value.utf8.count
        if start + count <= input.count,
           value.utf8.withUnsafeBufferPointer({ memcmp($0.baseAddress!, input.baseAddress! + start, count) == 0 }) {
            return start + count
        }
        if let end = matchEncoded(value, in: input, at: start, preferEncoded: true) { return end }
        return value.ambiguous ? matchEncoded(value, in: input, at: start, preferEncoded: false) : nil
    }

    /// Reads `value` character by character, each written literally or in
    /// one of its encoded forms. A character that starts an encoded form
    /// itself (a `%`) is read as that form first, or literally first.
    private func matchEncoded(_ value: Value, in input: UnsafeBufferPointer<UInt8>, at start: Int, preferEncoded: Bool) -> Int? {
        var position = start
        for (scalar, bytes) in zip(value.scalars, value.scalarBytes) {
            guard position < input.count else { return nil }
            if preferEncoded, let end = Self.escaped(scalar, in: input, at: position) {
                position = end
            } else if let end = Self.bytes(bytes, in: input, at: position, preferEncoded: preferEncoded) {
                position = end
            } else if !preferEncoded, let end = Self.escaped(scalar, in: input, at: position) {
                position = end
            } else {
                return nil
            }
        }
        return position
    }

    /// A scalar's UTF-8 `bytes`, each literal or percent-encoded (either hex
    /// case, also twice: `%2540` for `@` in a URL inside a parameter), and
    /// a space also as `+`.
    private static func bytes(_ bytes: [UInt8], in input: UnsafeBufferPointer<UInt8>, at start: Int, preferEncoded: Bool) -> Int? {
        var position = start
        for byte in bytes {
            guard position < input.count else { return nil }
            if let length = percentEncodedLength(of: byte, in: input, at: position), preferEncoded || input[position] != byte {
                position += length
            } else if input[position] == byte {
                position += 1
            } else if byte == 0x20, input[position] == UInt8(ascii: "+") {
                position += 1
            } else {
                return nil
            }
        }
        return position
    }

    /// The length of `byte` percent-encoded once (`%HH`) or twice
    /// (`%25HH`) at `start`.
    private static func percentEncodedLength(of byte: UInt8, in input: UnsafeBufferPointer<UInt8>, at start: Int) -> Int? {
        guard input[start] == UInt8(ascii: "%") else { return nil }
        if hexByte(input, at: start + 1) == byte { return 3 }
        if has(input, at: start, "%25"), hexByte(input, at: start + 3) == byte { return 5 }
        return nil
    }

    /// `scalar` escaped as one character: JSON and JavaScript (`\"`, `\n`,
    /// `\uXXXX` with surrogate pairs, `\u{X}`, `\xHH`), JavaScript's
    /// `escape` (`%uXXXX`) and HTML (`&amp;`, `&#64;`, `&#x40;`, a numeric
    /// reference without its semicolon, a legacy name in upper case).
    private static func escaped(_ scalar: Unicode.Scalar, in input: UnsafeBufferPointer<UInt8>, at start: Int) -> Int? {
        guard start + 1 < input.count else { return nil }
        let kind = input[start + 1]
        switch input[start] {
        case UInt8(ascii: "\\"):
            if let short = jsonShortEscapes[scalar], kind == short { return start + 2 }
            if kind == UInt8(ascii: "x"), scalar.value < 0x100, hexValue(input, at: start + 2, digits: 2) == scalar.value {
                return start + 4
            }
            guard kind == UInt8(ascii: "u") else { return nil }
            if start + 2 < input.count, input[start + 2] == UInt8(ascii: "{") {
                guard let (value, end) = number(in: input, at: start + 3, hex: true, maximumDigits: 6),
                      value == scalar.value, end < input.count, input[end] == UInt8(ascii: "}") else { return nil }
                return end + 1
            }
            return utf16Escape(scalar, in: input, at: start)
        case UInt8(ascii: "%"):
            return kind == UInt8(ascii: "u") || kind == UInt8(ascii: "U") ? utf16Escape(scalar, in: input, at: start) : nil
        case UInt8(ascii: "&"):
            if kind == UInt8(ascii: "#") {
                let hex = start + 2 < input.count && (input[start + 2] | 0x20) == UInt8(ascii: "x")
                let digits = start + (hex ? 3 : 2)
                guard let (value, end) = number(in: input, at: digits, hex: hex, maximumDigits: hex ? 8 : 10),
                      value == scalar.value else { return nil }
                return end < input.count && input[end] == UInt8(ascii: ";") ? end + 1 : end
            }
            guard let name = htmlNames[scalar] else { return nil }
            var position = start + 1
            for byte in name.utf8 {
                guard position < input.count else { return nil }
                let read = input[position]
                guard read == byte || (scalar != "'" && read | 0x20 == byte) else { return nil }
                position += 1
            }
            return position < input.count && input[position] == UInt8(ascii: ";") ? position + 1 : nil
        default:
            return nil
        }
    }

    /// `scalar` as `\uXXXX` or `%uXXXX` (two of them, a surrogate pair,
    /// past the Basic Multilingual Plane) at `start`.
    private static func utf16Escape(_ scalar: Unicode.Scalar, in input: UnsafeBufferPointer<UInt8>, at start: Int) -> Int? {
        var position = start
        for unit in String(scalar).utf16 {
            guard position + 1 < input.count, input[position] == input[start],
                  input[position + 1] | 0x20 == UInt8(ascii: "u"),
                  hexValue(input, at: position + 2, digits: 4) == UInt32(unit) else { return nil }
            position += 6
        }
        return position
    }

    /// The decimal or hex number at `start` (at least one digit, read as
    /// far as digits go, up to `maximumDigits`) and where it ends.
    private static func number(in input: UnsafeBufferPointer<UInt8>, at start: Int, hex: Bool, maximumDigits: Int) -> (UInt32, Int)? {
        var value: UInt64 = 0
        var position = start
        while position < input.count {
            let digit: UInt32?
            if hex {
                digit = hexDigit(input[position])
            } else {
                digit = isDigit(input[position]) ? UInt32(input[position] - UInt8(ascii: "0")) : nil
            }
            guard let digit else { break }
            guard position - start < maximumDigits else { return nil }
            value = value * (hex ? 16 : 10) + UInt64(digit)
            position += 1
        }
        guard position > start, value <= UInt64(UInt32.max) else { return nil }
        return (UInt32(value), position)
    }

    private static let jsonShortEscapes: [Unicode.Scalar: UInt8] = [
        "\"": UInt8(ascii: "\""), "\\": UInt8(ascii: "\\"), "/": UInt8(ascii: "/"),
        "\u{08}": UInt8(ascii: "b"), "\u{0C}": UInt8(ascii: "f"), "\n": UInt8(ascii: "n"),
        "\r": UInt8(ascii: "r"), "\t": UInt8(ascii: "t"),
    ]

    /// HTML's named references for the characters an escaper replaces.
    /// All but `apos` are also valid in upper case.
    private static let htmlNames: [Unicode.Scalar: String] = [
        "&": "amp", "<": "lt", ">": "gt", "\"": "quot", "'": "apos",
    ]

    // MARK: Base64

    private static let isBase64: [Bool] = (0..<256).map { base64Digit(UInt8($0)) != nil }

    /// The 6-bit value of a standard or URL-safe Base64 character.
    private static func base64Digit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return byte - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return byte - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0") + 52
        case UInt8(ascii: "+"), UInt8(ascii: "-"): return 62
        case UInt8(ascii: "/"), UInt8(ascii: "_"): return 63
        default: return nil
        }
    }

    /// Values of at least this many bytes are looked for in every Base64
    /// run at every offset. A shorter value turns up by chance in the
    /// decoded bytes of unrelated runs (a 3-byte value in about one of
    /// every 16 million positions, so in a few percent of megabyte images
    /// per offset), so it is looked for only where it was before (at the
    /// run's own offset in a run of eight or more characters) and, at every
    /// offset, in a run no more than three characters longer than its own
    /// encoding (`btoa(pin)`, `"x" + btoa(pin)`).
    static let minimumBytesAtEveryOffset = 4

    /// The mask of a value the Base64 run `input[start..<end]` decodes to
    /// contain, read from each of its first four characters: a value's
    /// encoding can start at any character of a run (`"x" + btoa(value)`),
    /// and only a start in step with it decodes to the value's bytes.
    private func base64Mask(_ input: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int, buffer: inout [UInt8]) -> [UInt8]? {
        let length = end - start
        guard length >= 2 else { return nil }
        for offset in 0..<min(4, length - 1) {
            Self.decodeBase64(input, from: start + offset, to: end, into: &buffer)
            guard !buffer.isEmpty else { continue }
            let hit = buffer.withUnsafeBytes { decoded in
                values.first { value in
                    Self.looksFor(value, inRunOf: length, at: offset)
                        && value.utf8.withUnsafeBytes { memmem(decoded.baseAddress, decoded.count, $0.baseAddress, $0.count) != nil }
                }
            }
            if let hit { return hit.mask }
        }
        return nil
    }

    /// Whether `value` is looked for in a Base64 run of `length` characters
    /// read from character `offset` (``minimumBytesAtEveryOffset``).
    private static func looksFor(_ value: Value, inRunOf length: Int, at offset: Int) -> Bool {
        let count = value.utf8.count
        if count >= minimumBytesAtEveryOffset { return true }
        let encodedLength = (count * 4 + 2) / 3
        return length <= encodedLength + 3 || (offset == 0 && length >= 8)
    }

    /// Decodes `input[start..<end]` (Base64 characters only, no padding):
    /// whole groups of four, then a last group of two or three.
    private static func decodeBase64(_ input: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int, into buffer: inout [UInt8]) {
        buffer.removeAll(keepingCapacity: true)
        var accumulator: UInt32 = 0
        var bits = 0
        for index in start..<end {
            accumulator = (accumulator << 6) | UInt32(base64Digit(input[index]) ?? 0)
            bits += 6
            if bits >= 8 {
                bits -= 8
                buffer.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
                accumulator &= (1 << UInt32(bits)) - 1
            }
        }
    }

    // MARK: Bytes

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func has(_ input: UnsafeBufferPointer<UInt8>, at start: Int, _ text: String) -> Bool {
        var position = start
        for byte in text.utf8 {
            guard position < input.count, input[position] == byte else { return false }
            position += 1
        }
        return true
    }

    private static func hexDigit(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(byte - UInt8(ascii: "A") + 10)
        default: return nil
        }
    }

    private static func hexValue(_ input: UnsafeBufferPointer<UInt8>, at start: Int, digits: Int) -> UInt32? {
        guard start + digits <= input.count else { return nil }
        var value: UInt32 = 0
        for index in start..<start + digits {
            guard let digit = hexDigit(input[index]) else { return nil }
            value = value << 4 | digit
        }
        return value
    }

    private static func hexByte(_ input: UnsafeBufferPointer<UInt8>, at start: Int) -> UInt8? {
        hexValue(input, at: start, digits: 2).map { UInt8($0) }
    }
}
