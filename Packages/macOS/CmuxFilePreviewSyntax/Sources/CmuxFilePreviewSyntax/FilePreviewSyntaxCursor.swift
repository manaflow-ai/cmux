/// A scalar cursor that tracks UTF-16 offsets for TextKit-compatible token ranges.
struct FilePreviewSyntaxCursor {
    private static let cancellationCheckInterval = 4_096

    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var advancesUntilCancellationCheck = 0
    private(set) var utf16Offset = 0
    private(set) var wasCancelled = false

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
        guard index < scalars.count, !wasCancelled else { return }
        if advancesUntilCancellationCheck == 0 {
            wasCancelled = Task.isCancelled
            advancesUntilCancellationCheck = Self.cancellationCheckInterval
            guard !wasCancelled else { return }
        }
        utf16Offset += scalars[index].value > 0xFFFF ? 2 : 1
        index += 1
        advancesUntilCancellationCheck -= 1
    }

    mutating func advance(_ count: Int) {
        for _ in 0..<count { advance() }
    }

    mutating func advanceWhile(_ predicate: (Unicode.Scalar) -> Bool) {
        while let scalar = current, !wasCancelled, predicate(scalar) {
            advance()
        }
    }

    mutating func advanceToEndOfLine() {
        while let scalar = current,
              !wasCancelled,
              scalar != "\n",
              scalar != "\r" {
            advance()
        }
    }

    mutating func advanceUntilMatch(_ pattern: [Unicode.Scalar]) {
        while current != nil, !wasCancelled {
            if matches(pattern) {
                advance(pattern.count)
                return
            }
            advance()
        }
    }

    mutating func consumeIdentifier(
        where isContinuation: (Unicode.Scalar) -> Bool
    ) -> String {
        var result = ""
        while let scalar = current,
              !wasCancelled,
              isContinuation(scalar) {
            result.unicodeScalars.append(scalar)
            advance()
        }
        return result
    }

    func matches(_ pattern: [Unicode.Scalar]) -> Bool {
        guard !pattern.isEmpty,
              index + pattern.count <= scalars.count else { return false }
        for offset in 0..<pattern.count
            where scalars[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    func nextNonSpaceScalar() -> Unicode.Scalar? {
        var probe = index
        var scannedCount = 0
        while probe < scalars.count {
            if scannedCount.isMultiple(of: Self.cancellationCheckInterval),
               Task.isCancelled {
                return nil
            }
            let scalar = scalars[probe]
            if scalar == " " || scalar == "\t" {
                probe += 1
                scannedCount += 1
                continue
            }
            return scalar
        }
        return nil
    }

    func range(from start: Int) -> Range<Int> {
        start..<utf16Offset
    }
}
