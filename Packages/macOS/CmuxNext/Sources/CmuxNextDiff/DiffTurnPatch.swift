public import CmuxNextSettings
import Foundation

/// A chat turn's changes as one unified patch the diff page reads (D2, Last turn): the session
/// host's `git.checkpoint.diff` reply (`git.diff`'s shape: `files` with `path`, `previous_path`,
/// `status`, `binary`, and each file's `patch` from its first `@@` line) with the git headers put
/// back, so the page opens it as the sidecar's `patch` source.
///
/// A cmux checkpoint is not a plain commit (its tree holds the worktree, index and untracked
/// trees), so neither the sidecar nor the page can diff a pair with git: the session host must.
/// Follow-up (diff-host.md, logic in Rust): a raw patch option on `git.checkpoint.diff`, then this
/// type only relays it.
nonisolated enum DiffTurnPatch {
    /// The request path of the tab's turn patch in its grant's manifest.
    static let requestPath = "/turn.patch"
    /// The page's `DiffSource` for the turn: the page names a patch source Last turn.
    static let pageSource: JSONValue = ["kind": "patch", "path": .string(requestPath)]

    /// Whether the page's `sessionOpen` params open the turn patch.
    static func opens(_ params: [String: JSONValue]) -> Bool {
        params["source"]?["kind"]?.stringValue == "patch" && params["source"]?["path"]?.stringValue == requestPath
    }

    /// The patch of every file in `diff`, in its order. A file the session host cut short ends
    /// with the part of its last hunk that came, its counts fixed; a file with no patch (binary,
    /// too large) keeps its header.
    static func make(_ diff: JSONValue) -> String {
        var out = ""
        for file in diff["files"]?.arrayValue ?? [] {
            guard let path = file["path"]?.stringValue, !path.isEmpty else { continue }
            let status = file["status"]?.stringValue ?? "modified"
            let old = status == "renamed" ? file["previous_path"]?.stringValue ?? path : path
            let added = status == "added" || status == "untracked"
            let deleted = status == "deleted"
            out += "diff --git \(quoted("a/" + old)) \(quoted("b/" + path))\n"
            if added { out += "new file mode 100644\n" }
            if deleted { out += "deleted file mode 100644\n" }
            var hunks = file["patch"]?.stringValue ?? ""
            if file["patch_truncated"]?.boolValue == true { hunks = cutHunks(hunks) }
            // The page tells a pure rename from an edited one by git's similarity line only.
            if old != path {
                let pure = hunks.isEmpty && file["patch_truncated"]?.boolValue != true && file["binary"]?.boolValue != true
                    && (file["additions"]?.intValue ?? 0) + (file["deletions"]?.intValue ?? 0) == 0
                out += "similarity index \(pure ? 100 : 50)%\n"
                out += "rename from \(quoted(old))\nrename to \(quoted(path))\n"
            }
            let from = added ? "/dev/null" : quoted("a/" + old)
            let to = deleted ? "/dev/null" : quoted("b/" + path)
            if file["binary"]?.boolValue == true {
                out += "Binary files \(from) and \(to) differ\n"
                continue
            }
            guard !hunks.isEmpty else { continue }
            out += "--- \(from)\n+++ \(to)\n" + hunks
            if !hunks.hasSuffix("\n") { out += "\n" }
        }
        return out
    }

    /// `patch` cut short at a line end: its last hunk's header counts the lines that came, so
    /// the page reads the hunks it has.
    static func cutHunks(_ patch: String) -> String {
        var lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard let header = lines.lastIndex(where: { $0.hasPrefix("@@ ") }),
              let starts = hunkStarts(lines[header]) else { return "" }
        let body = lines[(header + 1)...].filter { !$0.hasPrefix("\\") }
        let old = body.filter { !$0.hasPrefix("+") }.count, new = body.filter { !$0.hasPrefix("-") }.count
        guard old + new > 0 else { return lines[..<header].map { $0 + "\n" }.joined() }
        lines[header] = "@@ -\(starts.old),\(old) +\(starts.new),\(new) @@"
        return lines.map { $0 + "\n" }.joined()
    }

    /// The old and new start lines of hunk header `line` (`@@ -12,3 +12,4 @@`).
    private static func hunkStarts(_ line: String) -> (old: Int, new: Int)? {
        let fields = line.split(separator: " ")
        guard fields.count >= 3, fields[1].hasPrefix("-"), fields[2].hasPrefix("+"),
              let old = Int(fields[1].dropFirst().split(separator: ",").first ?? ""),
              let new = Int(fields[2].dropFirst().split(separator: ",").first ?? "") else { return nil }
        return (old, new)
    }

    /// `path` in git's C-style quotes when it holds a quote, a backslash or a control character.
    static func quoted(_ path: String) -> String {
        guard path.unicodeScalars.contains(where: { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }) else {
            return path
        }
        var out = "\""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: out += String(format: "\\%03o", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
