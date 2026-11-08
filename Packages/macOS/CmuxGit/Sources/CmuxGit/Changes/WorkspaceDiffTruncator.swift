import Foundation

/// Applies the workspace diff's byte and line caps at complete-hunk boundaries.
struct WorkspaceDiffTruncator {
    static let defaultMaximumBytes = 400 * 1024
    static let defaultMaximumLines = 6_000
    static let responseMaximumBytes = 6 * 1024 * 1024
    static let abuseGuardMaximumLines = 1_000_000
    static let readHeadroomBytes = 1 * 1024 * 1024

    let maximumBytes: Int
    let maximumLines: Int

    init(
        maximumBytes: Int = Self.defaultMaximumBytes,
        maximumLines: Int = Self.defaultMaximumLines
    ) {
        self.maximumBytes = maximumBytes
        self.maximumLines = maximumLines
    }

    init(requestedMaximumLines: Int?) {
        guard let requestedMaximumLines else {
            self.init()
            return
        }
        let clampedLines = min(
            max(requestedMaximumLines, Self.defaultMaximumLines),
            Self.abuseGuardMaximumLines
        )
        let scaledBytes = (
            clampedLines * Self.defaultMaximumBytes + Self.defaultMaximumLines - 1
        ) / Self.defaultMaximumLines
        self.init(
            maximumBytes: min(scaledBytes, Self.responseMaximumBytes),
            maximumLines: clampedLines
        )
    }

    var maximumInputBytes: Int {
        maximumBytes * 2 + Self.readHeadroomBytes
    }

    func truncate(_ diff: String) -> (text: String, truncated: Bool, totalLineCount: Int) {
        // Split on the literal newline, not Character: Swift treats "\r\n" as
        // one grapheme cluster, so a Character split never breaks CRLF lines
        // and collapses entire CRLF hunk bodies into one mega-line (the iOS
        // UnifiedDiffParser makes the same choice for the same reason).
        let lines = diff.components(separatedBy: "\n")
        guard diff.utf8.count > maximumBytes || lines.count > maximumLines else {
            return (diff, false, lines.count)
        }

        let hunkStarts = lines.indices.filter { lines[$0].hasPrefix("@@") }
        guard let firstHunkStart = hunkStarts.first else {
            let bounded = cappedPrefix(of: lines)
            return (bounded.text, bounded.truncated, lines.count)
        }

        var accepted = Array(lines[..<firstHunkStart])
        guard fits(accepted) else {
            let bounded = cappedPrefix(of: accepted)
            return (bounded.text, bounded.truncated, lines.count)
        }
        var acceptedBytes = byteCount(of: accepted)
        for (offset, hunkStart) in hunkStarts.enumerated() {
            let end = offset + 1 < hunkStarts.count ? hunkStarts[offset + 1] : lines.endIndex
            let hunk = lines[hunkStart..<end]
            let separatorBytes = accepted.isEmpty ? 0 : 1
            let hunkBytes = byteCount(of: hunk)
            guard accepted.count + hunk.count <= maximumLines,
                  acceptedBytes + separatorBytes + hunkBytes <= maximumBytes else { break }
            accepted.append(contentsOf: hunk)
            acceptedBytes += separatorBytes + hunkBytes
        }
        if accepted.count == firstHunkStart {
            // Not even the first hunk fit whole. Emit as much of it as the
            // caps allow under a header rewritten to describe the partial
            // body, instead of a contentless header-only diff.
            let end = hunkStarts.count > 1 ? hunkStarts[1] : lines.endIndex
            let hunk = Array(lines[firstHunkStart..<end])
            var body: [String] = []
            var bytes = acceptedBytes + (accepted.isEmpty ? 0 : 1) + hunk[0].utf8.count
            for line in hunk.dropFirst() {
                let lineBytes = line.utf8.count + 1
                guard accepted.count + 1 + body.count + 1 <= maximumLines,
                      bytes + lineBytes <= maximumBytes else { break }
                body.append(line)
                bytes += lineBytes
            }
            if !body.isEmpty {
                accepted.append(partialHunkHeader(from: hunk[0], including: body))
                accepted.append(contentsOf: body)
            }
        }
        return (accepted.joined(separator: "\n"), true, lines.count)
    }

    /// Rewrites `@@ -a,b +c,d @@` so the old/new counts describe exactly the
    /// included partial body; start lines are preserved.
    private func partialHunkHeader(from header: String, including body: [String]) -> String {
        let pattern = /@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/
        guard let match = header.firstMatch(of: pattern) else { return header }
        let old = body.count { $0.hasPrefix("-") || $0.hasPrefix(" ") }
        let new = body.count { $0.hasPrefix("+") || $0.hasPrefix(" ") }
        return "@@ -\(match.1),\(old) +\(match.2),\(new) @@"
    }

    private func fits(_ lines: [String]) -> Bool {
        lines.count <= maximumLines && byteCount(of: lines) <= maximumBytes
    }

    private func byteCount<C: Collection>(of lines: C) -> Int where C.Element == String {
        let contentBytes = lines.reduce(0) { $0 + $1.utf8.count }
        return contentBytes + max(0, lines.count - 1)
    }

    private func cappedPrefix(of lines: [String]) -> (text: String, truncated: Bool) {
        var accepted: [String] = []
        var bytes = 0
        for line in lines {
            let lineBytes = line.utf8.count + (accepted.isEmpty ? 0 : 1)
            guard accepted.count < maximumLines, bytes + lineBytes <= maximumBytes else { break }
            accepted.append(line)
            bytes += lineBytes
        }
        return (accepted.joined(separator: "\n"), true)
    }
}
