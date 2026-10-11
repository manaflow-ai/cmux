import Foundation

/// One hunk of a file's `git diff` as a patch `git apply` takes (cx-ncc.74): Stage hunk names the
/// hunk by its lines; the patch is built only from the App's own read of the diff.
nonisolated enum AgentPaneGitHunk {
    /// The patch of the hunk in `diff` (one file's `git diff` output) whose lines, less git's
    /// `\ No newline at end of file` markers, are `lines`: the file's header lines, then that hunk.
    /// A CRLF file's lines end in `\r` in the diff but not in the page's (changes/model.ts).
    /// Nil when no hunk or more than one has those lines, or `diff` holds more than one file.
    static func patch(of lines: [String], in diff: String) -> String? {
        var rows = diff.components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }
        guard let start = rows.firstIndex(where: { $0.hasPrefix("diff --git ") }),
              rows[(start + 1)...].allSatisfy({ !$0.hasPrefix("diff --git ") }),
              let first = rows[start...].firstIndex(where: { $0.hasPrefix("@@") }) else { return nil }
        let header = rows[start..<first]
        var hunks: [ArraySlice<String>] = []
        var at = first
        while at < rows.endIndex {
            let end = rows[(at + 1)...].firstIndex { $0.hasPrefix("@@") } ?? rows.endIndex
            hunks.append(rows[at..<end])
            at = end
        }
        let matches = hunks.filter { hunk in
            hunk.dropFirst().filter { !$0.hasPrefix("\\") }.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 } == lines
        }
        guard matches.count == 1, let hunk = matches.first else { return nil }
        return (header + hunk).joined(separator: "\n") + "\n"
    }
}
