import Foundation

/// Turns ripgrep's stdout, in arbitrary chunks, into grouped matches.
///
/// Owned by one background task at a time. It keeps only the unfinished
/// trailing line between calls, so memory tracks the output rate rather than
/// the total output size.
public final class RipgrepStreamDecoder {
    /// Stop after this many matches.
    public let matchLimit: Int
    public private(set) var matchCount = 0
    /// True once `matchLimit` matches were decoded; later input is ignored.
    public private(set) var isLimitReached = false
    private var pending: [UInt8] = []
    private let parser: RipgrepJSONLineParser

    public init(matchLimit: Int, parser: RipgrepJSONLineParser = RipgrepJSONLineParser()) {
        self.matchLimit = max(1, matchLimit)
        self.parser = parser
    }

    /// Decodes every complete line in `chunk`.
    public func consume<Bytes: Collection<UInt8>>(_ chunk: Bytes) -> [FileSearchFileMatches] {
        guard !isLimitReached else { return [] }
        pending.append(contentsOf: chunk)
        var output: [FileSearchFileMatches] = []
        var lineStart = 0
        pending.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            while lineStart < buffer.count, !isLimitReached {
                let remaining = buffer.count - lineStart
                guard let newline = memchr(base + lineStart, 0x0A, remaining) else { break }
                let lineEnd = base.distance(to: newline.assumingMemoryBound(to: UInt8.self))
                decodeLine(UnsafeBufferPointer(rebasing: buffer[lineStart..<lineEnd]), into: &output)
                lineStart = lineEnd + 1
            }
        }
        if isLimitReached {
            pending.removeAll()
        } else if lineStart > 0 {
            pending.removeFirst(lineStart)
        }
        return output
    }

    /// Decodes an unterminated final line, if any.
    public func finish() -> [FileSearchFileMatches] {
        guard !isLimitReached, !pending.isEmpty else {
            pending.removeAll()
            return []
        }
        var output: [FileSearchFileMatches] = []
        let line = pending
        pending.removeAll()
        line.withUnsafeBufferPointer { decodeLine($0, into: &output) }
        return output
    }

    private func decodeLine(_ line: UnsafeBufferPointer<UInt8>, into output: inout [FileSearchFileMatches]) {
        guard var group = parser.parseMatch(line: line) else { return }
        // "Limited" means a match was dropped, so a search with exactly
        // `matchLimit` results still completes normally.
        let room = matchLimit - matchCount
        if group.matches.count > room {
            group.matches = Array(group.matches.prefix(room))
            isLimitReached = true
        }
        guard !group.matches.isEmpty else { return }
        matchCount += group.matches.count
        output.appendMerging([group])
    }
}
