import Foundation

/// One hunk of a file's `git diff` as a patch `git apply` takes (cx-ncc.74): Stage hunk names the
/// hunk by its lines; the patch is built only from the App's own read of the diff.
nonisolated enum AgentPaneGitHunk {
    /// The header rows a one-file diff may have before its first hunk. Anything else (git's
    /// warnings share the read's output) refuses the patch rather than reaching `git apply`.
    private static let headerPrefixes = [
        "diff --git ", "index ", "--- ", "+++ ", "old mode ", "new mode ", "similarity index ",
        "dissimilarity index ", "rename from ", "rename to ", "copy from ", "copy to ",
        "new file mode ", "deleted file mode ",
    ]

    /// The patch of the hunk in `diff` (one file's `git diff` output) whose lines, less git's
    /// `\ No newline at end of file` markers, are `lines`: the file's header lines, then that hunk.
    /// A CRLF file's lines end in `\r` in the diff but not in the page's (changes/model.ts). The
    /// header drops a mode change, so only the hunk's content is staged, and a rename's or copy's
    /// header becomes a change to its new path, so unstaging a hunk keeps the rename staged.
    /// Nil when no hunk or more than one has those lines, `diff` holds more than one file or a row
    /// git's diff would not print, or its text was not UTF-8 (staging it would write U+FFFD).
    static func patch(of lines: [String], in diff: String) -> String? {
        guard !diff.contains("\u{FFFD}") else { return nil }
        var rows = diff.components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }
        guard let start = rows.firstIndex(where: { $0.hasPrefix("diff --git ") }),
              rows[(start + 1)...].allSatisfy({ !$0.hasPrefix("diff --git ") }),
              let first = rows[start...].firstIndex(where: { $0.hasPrefix("@@") }) else { return nil }
        let header = rows[start..<first]
        guard header.allSatisfy({ row in headerPrefixes.contains { row.hasPrefix($0) } }),
              rows[first...].allSatisfy({ row in row.hasPrefix("@@") || isHunkRow(row) || row.utf8.first == UInt8(ascii: "\\") })
        else { return nil }
        var hunks: [ArraySlice<String>] = []
        var at = first
        while at < rows.endIndex {
            let end = rows[(at + 1)...].firstIndex { $0.hasPrefix("@@") } ?? rows.endIndex
            hunks.append(rows[at..<end])
            at = end
        }
        let matches = hunks.filter { hunk in
            hunk.dropFirst().filter { $0.utf8.first != UInt8(ascii: "\\") }.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 } == lines
        }
        guard matches.count == 1, let hunk = matches.first else { return nil }
        let kept = header.filter { !$0.hasPrefix("old mode ") && !$0.hasPrefix("new mode ") }
        return (contentHeader(kept) + hunk).joined(separator: "\n") + "\n"
    }

    /// `header` as a change to its new path when it renames or copies (`git apply --reverse` of a
    /// rename would undo the rename too), else as it is.
    private static func contentHeader(_ header: [String]) -> [String] {
        guard header.contains(where: { $0.hasPrefix("rename from ") || $0.hasPrefix("copy from ") }),
              let new = header.first(where: { $0.hasPrefix("+++ ") })?.dropFirst(4) else { return header }
        let old = new.hasPrefix("\"b/") ? "\"a/" + new.dropFirst(3) : new.hasPrefix("b/") ? "a/" + new.dropFirst(2) : String(new)
        return ["diff --git \(old) \(new)", "--- \(old)", "+++ \(new)"]
    }

    /// A hunk line: ` `, `-` or `+` then its text (bytes, so a leading combining mark still counts).
    static func isHunkRow(_ row: String) -> Bool {
        [UInt8(ascii: " "), UInt8(ascii: "-"), UInt8(ascii: "+")].contains(row.utf8.first ?? 0)
    }
}
