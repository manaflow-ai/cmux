import Foundation

/// One left-to-right pass over bytes that masks a secret store's values
/// (``BrowserReplSecretStore``).
///
/// The pass never rescans its own output and never builds an intermediate
/// copy: at each position of the input it checks, in order, a Base64 token that starts
/// there, a whole number of a length masked by its shape, and each value in
/// any of its encodings, copying unmatched bytes through. Only values whose
/// first byte the position can start are tried: the byte itself, or the
/// first byte of the character an escape there (`%41`, `\u0041`, `&#65;`,
/// `+`) stands for.
///
/// Its work is bounded by the input's length: values that share a long
/// prefix could make each position run a long way into every one of them
/// before failing, so a pass that has compared more than ``workPerByte``
/// bytes per input byte (and a fixed allowance) stops and reports
/// ``Outcome/overLimit``, as for growth.
///
/// The pass runs on a session's JavaScript thread, inside a synchronous
/// host call, where the cell's timeout cannot stop it; it asks the caller's
/// `isCancelled` once per ``cancellationStride`` input bytes (and as often
/// inside a long Base64 run) and stops with ``Outcome/cancelled``.
///
/// A mask is longer than a short value, so masking can grow the input
/// (a one-character value with a 64-character name grows 73 times). The
/// growth is bounded by a budget the caller passes: a pass that would
/// exceed it stops and reports ``Outcome/overLimit`` instead of allocating
/// more. Adjacent matches of one mask become a single mask.
///
/// Every position is tried, also one inside an earlier match, so a value
/// that overlaps another (registered to end inside it) never hides it:
/// intersecting matches are masked as their union.
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
        /// `isCancelled` said so before the pass finished.
        case cancelled
    }

    private let values: [Value]
    /// The mask of every whole number with this many digits (index), or
    /// `nil`: values from a set small enough to guess whole (TOTP codes,
    /// short digit-only values) are masked by their shape, never compared
    /// (``BrowserReplSecretStore/masksByShape(_:)``).
    private let digitRunMasks: [[UInt8]?]
    /// Bytes at which some value's match can start.
    private let startBytes: [Bool]
    /// The values (indices into `values`, longest first) whose UTF-8 starts
    /// with each byte.
    private let valuesByFirstByte: [[Int]]

    /// Matching work (bytes and characters compared) a pass may do per
    /// input byte, past ``workAllowance``.
    static let workPerByte = 64
    /// Matching work any pass may do, so short inputs never hit the limit.
    static let workAllowance = 1 << 20
    /// How many input (or decoded) bytes a pass handles between checks of
    /// `isCancelled`.
    static let cancellationStride = 1 << 16

    /// - Parameters:
    ///   - values: The values to mask, longest first.
    ///   - digitRunMasks: The mask of every whole number with as many
    ///     digits as the index, or `nil`.
    init(values: [Value], digitRunMasks: [[UInt8]?] = []) {
        self.values = values
        self.digitRunMasks = digitRunMasks
        var startBytes = [Bool](repeating: false, count: 256)
        var valuesByFirstByte = [[Int]](repeating: [], count: 256)
        for (index, value) in values.enumerated() {
            guard let first = value.utf8.first else { continue }
            valuesByFirstByte[Int(first)].append(index)
            startBytes[Int(first)] = true
            for byte in "%\\&".utf8 { startBytes[Int(byte)] = true }
            if value.scalars.first == " " { startBytes[Int(UInt8(ascii: "+"))] = true }
        }
        self.startBytes = startBytes
        self.valuesByFirstByte = valuesByFirstByte
    }

    var isEmpty: Bool { values.isEmpty && !digitRunMasks.contains { $0 != nil } }

    /// Masks `input`. `budget` is how many bytes the output may grow past
    /// the input; it is reduced by the growth of this pass. `isCancelled`
    /// stops a long pass (``Outcome/cancelled``).
    ///
    /// Every position is tried against the original input, also one inside
    /// a match: agent code can register a value that overlaps a protected
    /// one (the characters just before it), and a match of that value must
    /// not hide the protected value's start. Intersecting matches are masked
    /// as their union, each distinct mask once in the order they start.
    func redact(_ input: UnsafeBufferPointer<UInt8>, budget: inout Int, isCancelled: () -> Bool = { false }) -> Outcome {
        guard !isEmpty, !input.isEmpty else { return .unchanged }
        var pass = Pass(input: input, budget: budget)
        var span = Span()
        var work = 0
        let workLimit = Self.workAllowance + input.count.multipliedReportingOverflow(by: Self.workPerByte).partialValue
        var index = 0
        var tokenCheckedUntil = 0
        var decoded: [UInt8] = []
        var cancelled = false
        while index < input.count {
            if index > 0, index % Self.cancellationStride == 0, isCancelled() { return .cancelled }
            let byte = input[index]
            let startsRun = index == 0 || !Self.isBase64[Int(input[index - 1])]
            if Self.isBase64[Int(byte)], startsRun, index >= tokenCheckedUntil {
                var end = index
                while end < input.count, Self.isBase64[Int(input[end])] { end += 1 }
                let mask = base64Mask(
                    input, from: index, to: end, buffer: &decoded, work: &work, workLimit: workLimit,
                    isCancelled: isCancelled, cancelled: &cancelled
                )
                if cancelled { return .cancelled }
                guard work <= workLimit else { return .overLimit }
                if let mask {
                    var padded = end
                    while padded < input.count, padded - end < 2, input[padded] == UInt8(ascii: "=") { padded += 1 }
                    guard span.add(from: index, to: padded, mask: mask, into: &pass) else { return .overLimit }
                }
                tokenCheckedUntil = end
            }
            // A whole number (no letter or digit on either side) is masked
            // by its length alone, whatever its digits, so the mask says
            // nothing about which number a value is.
            if !digitRunMasks.isEmpty, Self.isDigit(byte), index == 0 || !Self.isAlphanumeric(input[index - 1]) {
                var end = index
                while end < input.count, end - index < digitRunMasks.count, Self.isDigit(input[end]) { end += 1 }
                work += end - index
                let whole = end - index < digitRunMasks.count && (end == input.count || !Self.isAlphanumeric(input[end]))
                if whole, let mask = digitRunMasks[end - index] {
                    guard span.add(from: index, to: end, mask: mask, into: &pass) else { return .overLimit }
                }
            }
            if startBytes[Int(byte)] {
                var best: (end: Int, mask: [UInt8])?
                let firsts = Self.firstBytes(in: input, at: index)
                for slot in 0..<firsts.count {
                    for valueIndex in valuesByFirstByte[Int(firsts[slot])] {
                        let value = values[valueIndex]
                        if let end = match(value, in: input, at: index, work: &work), end > (best?.end ?? index) {
                            best = (end, value.mask)
                        }
                        guard work <= workLimit else { return .overLimit }
                    }
                }
                if let best {
                    guard span.add(from: index, to: best.end, mask: best.mask, into: &pass) else { return .overLimit }
                }
            }
            index += 1
        }
        guard span.flush(into: &pass) else { return .overLimit }
        guard let output = pass.finish() else { return .unchanged }
        budget = pass.budget
        return .redacted(output)
    }

    /// The union of the matches that intersect, not emitted yet: its range
    /// and each distinct mask of its matches, in the order they start (at
    /// most one per value or code, so bounded like the store).
    private struct Span {
        var start = 0
        var end = 0
        var masks: [[UInt8]] = []
        var seen: Set<[UInt8]> = []

        /// Adds the match `start..<end`: to this span when it starts inside
        /// it, else emits this span and starts a new one. False when the
        /// output would grow past the budget.
        mutating func add(from start: Int, to end: Int, mask: [UInt8], into pass: inout Pass) -> Bool {
            if masks.isEmpty || start >= self.end {
                guard flush(into: &pass) else { return false }
                self.start = start
                self.end = end
            } else {
                self.end = max(self.end, end)
            }
            if seen.insert(mask).inserted { masks.append(mask) }
            return true
        }

        /// Emits the span, if any. False when the output would grow past
        /// the budget.
        mutating func flush(into pass: inout Pass) -> Bool {
            guard !masks.isEmpty else { return true }
            let joined = masks.count == 1 ? masks[0] : Array(masks.joined())
            masks.removeAll(keepingCapacity: true)
            seen.removeAll(keepingCapacity: true)
            return pass.emit(from: start, to: end, mask: joined)
        }
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
    /// Adds the bytes and characters it compared to `work`.
    private func match(_ value: Value, in input: UnsafeBufferPointer<UInt8>, at start: Int, work: inout Int) -> Int? {
        let count = value.utf8.count
        let length = Self.commonPrefixLength(value.utf8, input, at: start)
        work += length + 1
        if length == count { return start + count }
        if let end = matchEncoded(value, in: input, at: start, preferEncoded: true, work: &work) { return end }
        return value.ambiguous ? matchEncoded(value, in: input, at: start, preferEncoded: false, work: &work) : nil
    }

    /// How many bytes of `bytes` `input` holds from `start` on.
    private static func commonPrefixLength(_ bytes: [UInt8], _ input: UnsafeBufferPointer<UInt8>, at start: Int) -> Int {
        let limit = min(bytes.count, input.count - start)
        var length = 0
        while length < limit, bytes[length] == input[start + length] { length += 1 }
        return length
    }

    /// The bytes a value that matches at `start` can start with: the byte
    /// there, and the first byte of the character a percent-encoding
    /// (once or twice), a `+` or an escape (`escaped`) there stands for.
    private static func firstBytes(in input: UnsafeBufferPointer<UInt8>, at start: Int) -> FirstBytes {
        var firsts = FirstBytes()
        firsts.insert(input[start])
        switch input[start] {
        case UInt8(ascii: "%"):
            if let byte = hexByte(input, at: start + 1) { firsts.insert(byte) }
            if has(input, at: start, "%25"), let byte = hexByte(input, at: start + 3) { firsts.insert(byte) }
        case UInt8(ascii: "+"):
            firsts.insert(0x20)
        default:
            break
        }
        if let scalar = escapedScalar(in: input, at: start), let byte = String(scalar).utf8.first {
            firsts.insert(byte)
        }
        return firsts
    }

    /// Up to four distinct bytes, kept without allocating.
    private struct FirstBytes {
        private var bytes: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        private(set) var count = 0

        subscript(index: Int) -> UInt8 {
            switch index {
            case 0: return bytes.0
            case 1: return bytes.1
            case 2: return bytes.2
            default: return bytes.3
            }
        }

        mutating func insert(_ byte: UInt8) {
            guard count < 4, !(0..<count).contains(where: { self[$0] == byte }) else { return }
            switch count {
            case 0: bytes.0 = byte
            case 1: bytes.1 = byte
            case 2: bytes.2 = byte
            default: bytes.3 = byte
            }
            count += 1
        }
    }

    /// The character an escape at `start` stands for, read as `escaped`
    /// reads one (every form it accepts reads as its character here), or
    /// nil when none starts there.
    private static func escapedScalar(in input: UnsafeBufferPointer<UInt8>, at start: Int) -> Unicode.Scalar? {
        guard start + 1 < input.count else { return nil }
        let kind = input[start + 1]
        switch input[start] {
        case UInt8(ascii: "\\"):
            if let scalar = jsonShortEscapes.first(where: { $0.value == kind })?.key { return scalar }
            if kind == UInt8(ascii: "x") { return hexValue(input, at: start + 2, digits: 2).flatMap(Unicode.Scalar.init) }
            guard kind | 0x20 == UInt8(ascii: "u") else { return nil }
            if start + 2 < input.count, input[start + 2] == UInt8(ascii: "{") {
                return number(in: input, at: start + 3, hex: true, maximumDigits: 6).flatMap { Unicode.Scalar($0.0) }
            }
            return utf16Scalar(in: input, at: start)
        case UInt8(ascii: "%"):
            return kind | 0x20 == UInt8(ascii: "u") ? utf16Scalar(in: input, at: start) : nil
        case UInt8(ascii: "&"):
            if kind == UInt8(ascii: "#") {
                let hex = start + 2 < input.count && (input[start + 2] | 0x20) == UInt8(ascii: "x")
                return number(in: input, at: start + (hex ? 3 : 2), hex: hex, maximumDigits: hex ? 8 : 10)
                    .flatMap { Unicode.Scalar($0.0) }
            }
            var best: (scalar: Unicode.Scalar, end: Int)?
            for name in htmlNamesByFirstByte[Int(kind)] {
                if let end = name.end(in: input, at: start + 1), end > (best?.end ?? start) { best = (name.scalar, end) }
            }
            return best?.scalar
        default:
            return nil
        }
    }

    /// The character `\uXXXX` or `%uXXXX` (a surrogate pair as two of
    /// them) at `start` stands for.
    private static func utf16Scalar(in input: UnsafeBufferPointer<UInt8>, at start: Int) -> Unicode.Scalar? {
        guard let high = hexValue(input, at: start + 2, digits: 4) else { return nil }
        if !(0xD800...0xDBFF).contains(high) { return Unicode.Scalar(high) }
        let next = start + 6
        guard next + 1 < input.count, input[next] == input[start], input[next + 1] | 0x20 == UInt8(ascii: "u"),
              let low = hexValue(input, at: next + 2, digits: 4), (0xDC00...0xDFFF).contains(low) else { return nil }
        return Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
    }

    /// Reads `value` character by character, each written literally or in
    /// one of its encoded forms. A character that starts an encoded form
    /// itself (a `%`) is read as that form first, or literally first.
    private func matchEncoded(_ value: Value, in input: UnsafeBufferPointer<UInt8>, at start: Int, preferEncoded: Bool, work: inout Int) -> Int? {
        var position = start
        for (scalar, bytes) in zip(value.scalars, value.scalarBytes) {
            work += 1
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
    /// reference without its semicolon, a name of HTML's legacy table such
    /// as `&lt`, `&AMP` or `&eacute` without its semicolon).
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
            var best: Int?
            for name in htmlNamesByFirstByte[Int(kind)] where name.scalar == scalar {
                if let end = name.end(in: input, at: start + 1), end > (best ?? start) { best = end }
            }
            return best
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

    /// An HTML named character reference, without its `&`.
    private struct HTMLName {
        let name: [UInt8]
        let scalar: Unicode.Scalar
        /// HTML reads a name of its legacy table also without the
        /// semicolon (`&amp`, `&lt`, `&eacute`); any other name needs it.
        let semicolonOptional: Bool

        /// Where the reference ends when it starts at `start` (just past
        /// the `&`): past its semicolon, or past the name when a legacy
        /// name has none. Names are case-sensitive (`&Eacute` is not
        /// `&eacute`).
        func end(in input: UnsafeBufferPointer<UInt8>, at start: Int) -> Int? {
            var position = start
            for byte in name {
                guard position < input.count, input[position] == byte else { return nil }
                position += 1
            }
            if position < input.count, input[position] == UInt8(ascii: ";") { return position + 1 }
            return semicolonOptional ? position : nil
        }
    }

    /// The HTML named references for the characters an escaper replaces
    /// and for Latin-1: every name of the HTML standard's legacy table
    /// (read with or without the semicolon), and `apos` (with it). Indexed
    /// by the name's first byte.
    private static let htmlNamesByFirstByte: [[HTMLName]] = {
        var table = [[HTMLName]](repeating: [], count: 256)
        let names = legacyHTMLNames.map { HTMLName(name: Array($0.0.utf8), scalar: Unicode.Scalar($0.1)!, semicolonOptional: true) }
            + [HTMLName(name: Array("apos".utf8), scalar: "'", semicolonOptional: false)]
        for name in names { table[Int(name.name[0])].append(name) }
        return table
    }()

    /// The HTML standard's named references that are valid without a
    /// semicolon (its legacy table), and the character each stands for.
    private static let legacyHTMLNames: [(String, UInt32)] = [
        ("AElig", 0xC6), ("AMP", 0x26), ("Aacute", 0xC1), ("Acirc", 0xC2), ("Agrave", 0xC0), ("Aring", 0xC5),
        ("Atilde", 0xC3), ("Auml", 0xC4), ("COPY", 0xA9), ("Ccedil", 0xC7), ("ETH", 0xD0), ("Eacute", 0xC9),
        ("Ecirc", 0xCA), ("Egrave", 0xC8), ("Euml", 0xCB), ("GT", 0x3E), ("Iacute", 0xCD), ("Icirc", 0xCE),
        ("Igrave", 0xCC), ("Iuml", 0xCF), ("LT", 0x3C), ("Ntilde", 0xD1), ("Oacute", 0xD3), ("Ocirc", 0xD4),
        ("Ograve", 0xD2), ("Oslash", 0xD8), ("Otilde", 0xD5), ("Ouml", 0xD6), ("QUOT", 0x22), ("REG", 0xAE),
        ("THORN", 0xDE), ("Uacute", 0xDA), ("Ucirc", 0xDB), ("Ugrave", 0xD9), ("Uuml", 0xDC), ("Yacute", 0xDD),
        ("aacute", 0xE1), ("acirc", 0xE2), ("acute", 0xB4), ("aelig", 0xE6), ("agrave", 0xE0), ("amp", 0x26),
        ("aring", 0xE5), ("atilde", 0xE3), ("auml", 0xE4), ("brvbar", 0xA6), ("ccedil", 0xE7), ("cedil", 0xB8),
        ("cent", 0xA2), ("copy", 0xA9), ("curren", 0xA4), ("deg", 0xB0), ("divide", 0xF7), ("eacute", 0xE9),
        ("ecirc", 0xEA), ("egrave", 0xE8), ("eth", 0xF0), ("euml", 0xEB), ("frac12", 0xBD), ("frac14", 0xBC),
        ("frac34", 0xBE), ("gt", 0x3E), ("iacute", 0xED), ("icirc", 0xEE), ("iexcl", 0xA1), ("igrave", 0xEC),
        ("iquest", 0xBF), ("iuml", 0xEF), ("laquo", 0xAB), ("lt", 0x3C), ("macr", 0xAF), ("micro", 0xB5),
        ("middot", 0xB7), ("nbsp", 0xA0), ("not", 0xAC), ("ntilde", 0xF1), ("oacute", 0xF3), ("ocirc", 0xF4),
        ("ograve", 0xF2), ("ordf", 0xAA), ("ordm", 0xBA), ("oslash", 0xF8), ("otilde", 0xF5), ("ouml", 0xF6),
        ("para", 0xB6), ("plusmn", 0xB1), ("pound", 0xA3), ("quot", 0x22), ("raquo", 0xBB), ("reg", 0xAE),
        ("sect", 0xA7), ("shy", 0xAD), ("sup1", 0xB9), ("sup2", 0xB2), ("sup3", 0xB3), ("szlig", 0xDF),
        ("thorn", 0xFE), ("times", 0xD7), ("uacute", 0xFA), ("ucirc", 0xFB), ("ugrave", 0xF9), ("uml", 0xA8),
        ("uuml", 0xFC), ("yacute", 0xFD), ("yen", 0xA5), ("yuml", 0xFF),
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
    /// Adds the bytes it decoded and compared to `work`, and stops (nil)
    /// once that passes `workLimit`, or when `isCancelled` says so (and sets
    /// `cancelled`).
    private func base64Mask(
        _ input: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int,
        buffer: inout [UInt8],
        work: inout Int,
        workLimit: Int,
        isCancelled: () -> Bool,
        cancelled: inout Bool
    ) -> [UInt8]? {
        let length = end - start
        guard length >= 2 else { return nil }
        let long = length > Self.cancellationStride
        for offset in 0..<min(4, length - 1) {
            if long, isCancelled() {
                cancelled = true
                return nil
            }
            Self.decodeBase64(input, from: start + offset, to: end, into: &buffer)
            work += length
            guard !buffer.isEmpty else { continue }
            let hit: Value? = buffer.withUnsafeBufferPointer { decoded in
                // Each decoded position tries only the values that start with its byte.
                for position in decoded.indices {
                    if position > 0, position % Self.cancellationStride == 0, isCancelled() {
                        cancelled = true
                        return nil
                    }
                    for valueIndex in valuesByFirstByte[Int(decoded[position])] {
                        let value = values[valueIndex]
                        guard Self.looksFor(value, inRunOf: length, at: offset) else { continue }
                        let matched = Self.commonPrefixLength(value.utf8, decoded, at: position)
                        work += matched + 1
                        if matched == value.utf8.count { return value }
                        if work > workLimit { return nil }
                    }
                }
                return nil
            }
            if let hit { return hit.mask }
            if cancelled || work > workLimit { return nil }
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

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte | 0x20 >= UInt8(ascii: "a") && byte | 0x20 <= UInt8(ascii: "z"))
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
