import Foundation

/// Cursor over source scalars that keeps UTF-16 offsets aligned with TextKit ranges.
struct FilePreviewSyntaxCursor {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private(set) var utf16Offset = 0

    init(source: String) {
        scalars = Array(source.unicodeScalars)
    }

    var current: Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    func peek(_ ahead: Int) -> Unicode.Scalar? {
        let target = index + ahead
        return target < scalars.count ? scalars[target] : nil
    }

    mutating func advance() {
        guard index < scalars.count else { return }
        utf16Offset += scalars[index].value > 0xFFFF ? 2 : 1
        index += 1
    }

    mutating func advance(_ count: Int) {
        for _ in 0..<count { advance() }
    }

    mutating func advanceWhile(_ predicate: (Unicode.Scalar) -> Bool) {
        while let scalar = current, !Task.isCancelled, predicate(scalar) { advance() }
    }

    mutating func advanceToEndOfLine() {
        while let scalar = current, !Task.isCancelled, scalar != "\n", scalar != "\r" { advance() }
    }

    mutating func advanceUntilMatch(_ pattern: [Unicode.Scalar]) {
        while current != nil, !Task.isCancelled {
            if matches(pattern) {
                advance(pattern.count)
                return
            }
            advance()
        }
    }

    mutating func consumeIdentifier(where isContinuation: (Unicode.Scalar) -> Bool) -> String {
        var result = ""
        while let scalar = current, !Task.isCancelled, isContinuation(scalar) {
            result.unicodeScalars.append(scalar)
            advance()
        }
        return result
    }

    func matches(_ pattern: [Unicode.Scalar]) -> Bool {
        guard !pattern.isEmpty, index + pattern.count <= scalars.count else { return false }
        for offset in 0..<pattern.count where scalars[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    func nextNonSpaceScalar() -> Unicode.Scalar? {
        var probe = index
        while probe < scalars.count {
            let scalar = scalars[probe]
            if scalar == " " || scalar == "\t" {
                probe += 1
                continue
            }
            return scalar
        }
        return nil
    }

    func range(from start: Int) -> NSRange {
        NSRange(location: start, length: utf16Offset - start)
    }
}
