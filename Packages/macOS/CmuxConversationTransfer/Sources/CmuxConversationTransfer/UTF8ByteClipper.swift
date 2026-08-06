/// Clips text to a UTF-8 byte budget without splitting a Unicode scalar.
public struct UTF8ByteClipper: Sendable {
    /// Creates a UTF-8 byte clipper.
    public init() {}

    /// Retains the beginning and end of text within a UTF-8 byte ceiling.
    ///
    /// ```swift
    /// let clipped = UTF8ByteClipper().clipped(message, maximumBytes: 4_000)
    /// ```
    ///
    /// - Parameters:
    ///   - text: Text to bound.
    ///   - maximumBytes: Maximum UTF-8 bytes in the returned string.
    /// - Returns: The original string when it fits, otherwise a valid UTF-8 head/tail excerpt.
    public func clipped(_ text: String, maximumBytes: Int) -> String {
        let byteLimit = max(0, maximumBytes)
        guard text.utf8.count > byteLimit else { return text }
        guard byteLimit > 0 else { return "" }

        let marker = "\n…\n"
        guard marker.utf8.count < byteLimit else {
            return prefix(marker, maximumBytes: byteLimit)
        }
        let contentBytes = byteLimit - marker.utf8.count
        let headBytes = contentBytes / 2
        let tailBytes = contentBytes - headBytes
        return prefix(text, maximumBytes: headBytes)
            + marker
            + suffix(text, maximumBytes: tailBytes)
    }

    func prefix(_ text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var usedBytes = 0
        var end = text.unicodeScalars.startIndex
        while end < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[end]
            let byteCount = scalar.utf8ByteCount
            guard byteCount <= maximumBytes - usedBytes else { break }
            usedBytes += byteCount
            end = text.unicodeScalars.index(after: end)
        }
        return String(text[..<end])
    }

    private func suffix(_ text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var usedBytes = 0
        var start = text.unicodeScalars.endIndex
        while start > text.unicodeScalars.startIndex {
            let previous = text.unicodeScalars.index(before: start)
            let byteCount = text.unicodeScalars[previous].utf8ByteCount
            guard byteCount <= maximumBytes - usedBytes else { break }
            usedBytes += byteCount
            start = previous
        }
        return String(text[start...])
    }
}

extension Unicode.Scalar {
    var utf8ByteCount: Int {
        switch value {
        case ...0x7f: 1
        case ...0x7ff: 2
        case ...0xffff: 3
        default: 4
        }
    }
}
