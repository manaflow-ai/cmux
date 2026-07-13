import Foundation

extension GitDiffService {
    /// A single-file RPC must never return multiple `diff --git` sections,
    /// even when a stale rename source and destination are both independently
    /// changed. Diff content lines always carry a unified-diff marker, so only
    /// an actual file-section header can start with this prefix.
    static func hasExactlyOneFileSection(_ output: String) -> Bool {
        var sectionCount = 0
        for line in GitProtocolLineSequence(output) where line.hasPrefix("diff --git ") {
            sectionCount += 1
            if sectionCount > 1 { return false }
        }
        return sectionCount == 1
    }

    /// Supplying `oldPath` asserts a rename. Requiring Git's rename metadata
    /// prevents two unrelated changes from masquerading as that one rename.
    static func hasRenameHeaders(_ output: String) -> Bool {
        var hasRenameFrom = false
        var hasRenameTo = false
        for line in GitProtocolLineSequence(output) {
            hasRenameFrom = hasRenameFrom || line.hasPrefix("rename from ")
            hasRenameTo = hasRenameTo || line.hasPrefix("rename to ")
        }
        return hasRenameFrom && hasRenameTo
    }
}

/// Git's text protocol uses the LF byte as its record separator. Iterating
/// Unicode `Character` newlines would also split valid content at U+2028 and
/// U+2029, while character-level LF searches can miss LF inside CRLF.
private struct GitProtocolLineSequence: Sequence, IteratorProtocol {
    private var remaining: Substring.UTF8View

    init(_ source: String) {
        remaining = source[...].utf8
    }

    mutating func next() -> String? {
        guard !remaining.isEmpty else { return nil }
        guard let newline = remaining.firstIndex(of: 0x0A) else {
            defer { remaining = remaining[remaining.endIndex...] }
            return Self.decodeLine(remaining)
        }
        let line = remaining[..<newline]
        remaining = remaining[remaining.index(after: newline)...]
        return Self.decodeLine(line)
    }

    private static func decodeLine(_ bytes: Substring.UTF8View.SubSequence) -> String {
        let content = bytes.last == 0x0D ? bytes.dropLast() : bytes
        return String(decoding: content, as: UTF8.self)
    }
}
