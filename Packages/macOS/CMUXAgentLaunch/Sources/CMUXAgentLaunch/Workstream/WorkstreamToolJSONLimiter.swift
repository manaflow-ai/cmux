import Foundation

/// Shortens a stored tool input or result so it fits a size limit and still
/// parses.
///
/// Cutting the serialized string leaves text that no longer parses and drops
/// every key after the long value: a Write's `content` sorts before its
/// `file_path`, so a reader of the cut text cannot tell which file the
/// request was for. This shortens the long string values in place instead,
/// each to the same length, the longest that fits, ending in `...`.
/// Everything else in the text (keys, numbers, order, escapes) stays as it
/// was stored.
public struct WorkstreamToolJSONLimiter: Sendable {
    /// The most Unicode scalars a shortened text may have. Scalars are never
    /// fewer than characters, so this also bounds the character count.
    public let scalarLimit: Int

    /// Creates a limiter for texts of at most `scalarLimit` Unicode scalars.
    public init(scalarLimit: Int) {
        self.scalarLimit = scalarLimit
    }

    /// `json` with its long string values shortened to fit ``scalarLimit``.
    ///
    /// - Returns: `nil` when `json` already fits, is not a JSON object or
    ///   array, has brackets or quotes that do not balance, or is still too
    ///   long with every string value shortened. The caller then keeps
    ///   whatever cut it used before.
    public func shortened(_ json: String) -> String? {
        let limit = scalarLimit
        guard json.utf8.count > limit else { return nil }
        let bytes = Array(json.utf8)
        // Scalars before each byte, so a cut's saving is a subtraction. All
        // ASCII text needs no table: every byte is one scalar.
        var scalarsBefore: [Int32] = []
        if bytes.contains(where: { $0 >= 0x80 }) {
            scalarsBefore.reserveCapacity(bytes.count + 1)
            var scalars: Int32 = 0
            for byte in bytes {
                scalarsBefore.append(scalars)
                if byte & 0xC0 != 0x80 { scalars += 1 }
            }
            scalarsBefore.append(scalars)
        }
        func scalarCount(_ range: Range<Int>) -> Int {
            scalarsBefore.isEmpty
                ? range.count
                : Int(scalarsBefore[range.upperBound] - scalarsBefore[range.lowerBound])
        }
        let total = scalarCount(0..<bytes.count)
        guard total > limit, let values = Self.stringValueRanges(in: bytes) else { return nil }
        // Where a value longer than `valueLimit` bytes ends once shortened,
        // leaving room for the "..." that marks the cut. A value the cut
        // would not make shorter is left alone.
        func cutIndex(_ range: Range<Int>, valueLimit: Int) -> Int? {
            guard range.count > valueLimit else { return nil }
            let end = Self.cutIndex(in: bytes, range: range, keeping: valueLimit - 3)
            return scalarCount(end..<range.upperBound) > 3 ? end : nil
        }
        func length(valueLimit: Int) -> Int {
            values.reduce(total) { length, range in
                guard let end = cutIndex(range, valueLimit: valueLimit) else { return length }
                return length - scalarCount(end..<range.upperBound) + 3
            }
        }
        var fits = 3
        guard length(valueLimit: fits) <= limit else { return nil }
        // A scalar is at most 4 bytes, and a cut can back off by up to 11.
        var tooLong = 4 * limit + 16
        while tooLong - fits > 1 {
            let candidate = fits + (tooLong - fits) / 2
            if length(valueLimit: candidate) <= limit {
                fits = candidate
            } else {
                tooLong = candidate
            }
        }
        var output: [UInt8] = []
        output.reserveCapacity(min(bytes.count, 4 * limit))
        var position = 0
        for range in values {
            guard let end = cutIndex(range, valueLimit: fits) else { continue }
            output.append(contentsOf: bytes[position..<end])
            output.append(contentsOf: [0x2E, 0x2E, 0x2E])
            position = range.upperBound
        }
        output.append(contentsOf: bytes[position...])
        return String(decoding: output, as: UTF8.self)
    }

    /// The byte ranges of the string values (not the keys) inside a JSON
    /// object or array, in order, without their quotes. `nil` when the text
    /// does not start with a container, or its brackets or quotes do not
    /// balance.
    private static func stringValueRanges(in bytes: [UInt8]) -> [Range<Int>]? {
        let count = bytes.count
        var index = 0
        func skipWhitespace() {
            while index < count {
                let byte = bytes[index]
                guard byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 else { return }
                index += 1
            }
        }
        skipWhitespace()
        guard index < count, bytes[index] == 0x7B || bytes[index] == 0x5B else { return nil }
        var ranges: [Range<Int>] = []
        var depth = 0
        while index < count {
            switch bytes[index] {
            case 0x7B, 0x5B:
                depth += 1
                index += 1
            case 0x7D, 0x5D:
                depth -= 1
                index += 1
                guard depth >= 0 else { return nil }
            case 0x22:
                let start = index + 1
                index = start
                while index < count, bytes[index] != 0x22 {
                    index += bytes[index] == 0x5C ? 2 : 1
                }
                guard index < count else { return nil }
                let end = index
                index += 1
                skipWhitespace()
                if index < count, bytes[index] == 0x3A { continue }
                ranges.append(start..<end)
            default:
                index += 1
            }
        }
        return depth == 0 ? ranges : nil
    }

    /// Where to cut the JSON string contents in `range` to keep at most
    /// `count` bytes without splitting a UTF-8 sequence, an escape, or a
    /// `\u` surrogate pair.
    private static func cutIndex(in bytes: [UInt8], range: Range<Int>, keeping count: Int) -> Int {
        let start = range.lowerBound
        var index = start + max(count, 0)
        while index > start, bytes[index] & 0xC0 == 0x80 {
            index -= 1
        }
        // A backslash starts an escape when an odd number of them end there.
        func startsEscape(_ position: Int) -> Bool {
            guard position >= start, bytes[position] == 0x5C else { return false }
            var run = 0
            var cursor = position
            while cursor >= start, bytes[cursor] == 0x5C {
                run += 1
                cursor -= 1
            }
            return run % 2 == 1
        }
        if startsEscape(index - 1) {
            index -= 1
        } else {
            for offset in 2...5 where startsEscape(index - offset) && bytes[index - offset + 1] == 0x75 {
                index -= offset
                break
            }
        }
        if startsEscape(index - 6), bytes[index - 5] == 0x75, bytes[index - 4] | 0x20 == 0x64 {
            let digit = bytes[index - 3] | 0x20
            if digit == 0x38 || digit == 0x39 || digit == 0x61 || digit == 0x62 {
                index -= 6
            }
        }
        return index
    }
}
