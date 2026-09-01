import Foundation

enum MarkdownPanelFileLinkResolver {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mkd", "mdx"]

    static func isMarkdownPathLike(_ rawPath: String) -> Bool {
        let trimmed = stripFragmentAndQuery(rawPath)
        guard !trimmed.isEmpty else { return false }
        // Keep this intentionally path-like: code spans such as `foo.md`,
        // `docs/foo.md`, `../foo.md`, or `/tmp/foo.md` qualify. URLs do not.
        if let url = URL(string: trimmed), url.scheme != nil, url.scheme != "file" {
            return false
        }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext)
    }

    /// Resolves a wiki-style link target (`[[Note]]` → `Note.md`) that did not
    /// resolve as a plain relative/sibling path, using Obsidian's vault model:
    /// find the note by name anywhere under the vault root (the nearest ancestor
    /// directory containing `.obsidian`). Returns `nil` when the current file is
    /// not inside an Obsidian vault or no matching note exists, so non-vault
    /// markdown keeps today's sibling-only behavior.
    static func resolveVaultWikiLink(
        rawPath: String,
        relativeToMarkdownFile markdownFilePath: String,
        anchorMarkerName: String = ".obsidian"
    ) -> String? {
        let stripped = stripFragmentAndQuery(rawPath)
        guard !stripped.isEmpty, !(stripped as NSString).isAbsolutePath else { return nil }
        guard isMarkdownPathLike(stripped) else { return nil }
        guard let vaultRoot = vaultRoot(forMarkdownFile: markdownFilePath, markerName: anchorMarkerName) else { return nil }

        // Prefer an exact relative subpath under the vault root, so a qualified
        // link like `[[folder/Note]]` beats a bare-name match elsewhere.
        let relCandidate = ((vaultRoot as NSString).appendingPathComponent(stripped) as NSString).standardizingPath
        if fileExistsAsMarkdown(relCandidate) {
            return relCandidate
        }

        // Otherwise resolve by leaf name anywhere in the vault.
        let targetLeaf = (stripped as NSString).lastPathComponent
        return findMarkdownFile(named: targetLeaf, under: vaultRoot)
    }

    /// Nearest ancestor of `markdownFilePath` (inclusive of its directory) that
    /// contains `markerName` (e.g. `.obsidian` for an Obsidian vault, `.git` for
    /// a Git repository) — the anchor for wiki-link resolution.
    ///
    /// The marker is matched as a file *or* directory: `.obsidian` is always a
    /// directory, but `.git` is a file in worktrees and submodules.
    static func vaultRoot(forMarkdownFile markdownFilePath: String, markerName: String = ".obsidian") -> String? {
        let fm = FileManager.default
        var dir = (markdownFilePath as NSString).deletingLastPathComponent
        var guardCount = 0
        while !dir.isEmpty, dir != "/", guardCount < 64 {
            let marker = (dir as NSString).appendingPathComponent(markerName)
            if fm.fileExists(atPath: marker) {
                return dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
            guardCount += 1
        }
        return nil
    }

    /// First markdown file whose leaf name equals `targetLeaf` (case-insensitive)
    /// under `root`, preferring the shallowest match. Skips hidden directories
    /// (`.obsidian`, `.git`, `.trash`, …) and bounds the scan for large vaults.
    private static func findMarkdownFile(named targetLeaf: String, under root: String) -> String? {
        let fm = FileManager.default
        let wantedLower = targetLeaf.lowercased()
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var best: String?
        var bestDepth = Int.max
        var scanned = 0
        let maxScan = 50_000
        for case let url as URL in enumerator {
            scanned += 1
            if scanned > maxScan { break }
            guard url.lastPathComponent.lowercased() == wantedLower else { continue }
            // `FileManager.enumerator` yields directories too, and has no depth
            // ordering guarantee — so a directory (or bundle) literally named
            // `Note.md` must not shadow a deeper regular `Note.md`.
            let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegularFile else { continue }
            let depth = url.pathComponents.count
            if depth < bestDepth {
                best = url.path
                bestDepth = depth
            }
        }
        return best
    }

    private static func fileExistsAsMarkdown(_ path: String) -> Bool {
        guard isMarkdownPathLike(path) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    static func resolve(rawPath: String, relativeToMarkdownFile markdownFilePath: String) -> String? {
        let stripped = stripFragmentAndQuery(rawPath)
        guard !stripped.isEmpty else { return nil }

        let candidatePaths: [String] = {
            if let url = URL(string: stripped), url.scheme == "file" {
                return [url.path]
            }
            if (stripped as NSString).isAbsolutePath {
                return [stripped]
            }
            let markdownDir = (markdownFilePath as NSString).deletingLastPathComponent
            let pwd = FileManager.default.currentDirectoryPath
            return [
                (markdownDir as NSString).appendingPathComponent(stripped),
                (pwd as NSString).appendingPathComponent(stripped)
            ]
        }()

        for path in candidatePaths {
            let standardized = (path as NSString).standardizingPath
            guard isMarkdownPathLike(standardized) else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir), !isDir.boolValue {
                return standardized
            }
        }
        return nil
    }

    private static func stripFragmentAndQuery(_ rawPath: String) -> String {
        var s = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = s.firstIndex(of: "#") {
            s = String(s[..<hash])
        }
        if let question = s.firstIndex(of: "?") {
            s = String(s[..<question])
        }
        return s.removingPercentEncoding ?? s
    }
}
