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

    static func isInPageFragment(_ url: URL, relativeToMarkdownFile markdownFilePath: String) -> Bool {
        // Only same-document anchors should stay inside the WebView. With
        // a file base URL, WebKit resolves `#heading` to
        // `file:///current.md#heading`; links such as `other.md#heading`
        // must still route through the markdown-tab opener below.
        guard url.fragment != nil else { return false }
        if (url.scheme == nil || url.scheme == "about"), (url.host ?? "").isEmpty {
            return true
        }
        if url.isFileURL {
            let targetPath = (url.path as NSString).standardizingPath
            let currentPath = (markdownFilePath as NSString).standardizingPath
            let currentDirectory = ((markdownFilePath as NSString).deletingLastPathComponent as NSString).standardizingPath
            return targetPath == currentPath || targetPath == currentDirectory
        }
        return false
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
