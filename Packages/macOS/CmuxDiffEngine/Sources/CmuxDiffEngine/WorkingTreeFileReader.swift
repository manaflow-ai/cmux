import Darwin
import Foundation

/// Reads regular worktree files without spawning one Git process per untracked path.
struct WorkingTreeFileReader: Sendable {
    let repositoryRoot: String

    func regularFileData(path: String) throws -> Data? {
        let url = try absoluteURL(path: path)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return nil }
        guard metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    func lines(path: String, startLine: Int, endLine: Int) throws -> [String] {
        guard startLine >= 1, endLine >= startLine else {
            throw DiffEngineError.invalidRange
        }
        guard let data = try regularFileData(path: path) else {
            throw DiffEngineError.fileNotFound(path)
        }
        return selectedLines(data: data, startLine: startLine, endLine: endLine)
    }

    func selectedLines(data: Data, startLine: Int, endLine: Int) -> [String] {
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.last == "\r" ? String(line.dropLast()) : String(line)
            }
        if data.last == 0x0A, lines.last == "" {
            lines.removeLast()
        }
        guard startLine <= lines.count else { return [] }
        return Array(lines[(startLine - 1)..<min(endLine, lines.count)])
    }

    func untrackedPatch(path: String, data: Data) -> (patch: Data, additions: Int, isBinary: Bool) {
        let isBinary = data.contains(0)
        if isBinary {
            let header = "diff --git a/\(path) b/\(path)\nnew file mode 100644\nBinary files /dev/null and b/\(path) differ\n"
            return (Data(header.utf8), 0, true)
        }
        let text = String(decoding: data, as: UTF8.self)
        var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hasTrailingNewline = data.last == 0x0A
        if hasTrailingNewline, rows.last == "" {
            rows.removeLast()
        }
        let additions = data.isEmpty ? 0 : rows.count
        var patch = "diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n"
        if additions > 0 {
            patch += "@@ -0,0 +1,\(additions) @@\n"
            patch += rows.map { "+" + $0 }.joined(separator: "\n")
            patch += "\n"
            if !hasTrailingNewline {
                patch += "\\ No newline at end of file\n"
            }
        }
        return (Data(patch.utf8), additions, false)
    }

    private func absoluteURL(path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw DiffEngineError.invalidPath(path)
        }
        let root = URL(fileURLWithPath: repositoryRoot, isDirectory: true).standardizedFileURL
        let candidate = root.appendingPathComponent(path, isDirectory: false).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let lexicalPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard candidate.path.hasPrefix(lexicalPrefix), resolvedCandidate.path.hasPrefix(prefix) else {
            throw DiffEngineError.invalidPath(path)
        }
        return candidate
    }
}
