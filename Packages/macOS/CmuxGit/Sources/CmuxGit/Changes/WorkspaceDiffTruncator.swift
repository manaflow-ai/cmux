import Foundation

/// Applies the workspace diff's byte and line caps at complete-hunk boundaries.
struct WorkspaceDiffTruncator {
    let maximumBytes: Int
    let maximumLines: Int

    init(maximumBytes: Int = 400 * 1024, maximumLines: Int = 6_000) {
        self.maximumBytes = maximumBytes
        self.maximumLines = maximumLines
    }

    func truncate(_ diff: String) -> (text: String, truncated: Bool) {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard diff.utf8.count > maximumBytes || lines.count > maximumLines else {
            return (diff, false)
        }

        let hunkStarts = lines.indices.filter { lines[$0].hasPrefix("@@") }
        guard let firstHunkStart = hunkStarts.first else {
            return cappedPrefix(of: lines)
        }

        var accepted = Array(lines[..<firstHunkStart])
        guard fits(accepted) else { return cappedPrefix(of: accepted) }
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
        return (accepted.joined(separator: "\n"), true)
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
        for line in lines {
            let candidate = accepted + [line]
            guard fits(candidate) else { break }
            accepted = candidate
        }
        return (accepted.joined(separator: "\n"), true)
    }
}
