import Foundation

enum MarkdownPanelFileLinkResolver {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mkd", "mdx"]
    private static let knownExternalSchemes: Set<String> = [
        "about", "blob", "data", "ftp", "http", "https", "javascript", "mailto", "sms", "tel"
    ]

    static func isMarkdownPathLike(_ rawPath: String) -> Bool {
        let trimmed = stripFragmentAndQuery(rawPath)
        guard !trimmed.isEmpty else { return false }
        // Keep this intentionally path-like: code spans such as `foo.md`,
        // `docs/foo.md`, `../foo.md`, or `/tmp/foo.md` qualify. URLs do not.
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme != "file",
           !shouldTreatUnknownSchemeAsRelativePath(trimmed, scheme: scheme) {
            return false
        }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext)
    }

    static func resolve(rawPath: String, relativeToMarkdownFile markdownFilePath: String) -> String? {
        guard let localFile = resolveLocalFile(rawPath: rawPath, relativeToMarkdownFile: markdownFilePath),
              isMarkdownPathLike(localFile) else {
            return nil
        }
        return localFile
    }

    static func resolveLocalFile(rawPath: String, relativeToMarkdownFile markdownFilePath: String) -> String? {
        let stripped = stripFragmentAndQuery(rawPath)
        guard !stripped.isEmpty else { return nil }

        for path in candidatePaths(for: stripped, relativeToMarkdownFile: markdownFilePath) {
            let standardized = (path as NSString).standardizingPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir), !isDir.boolValue {
                return standardized
            }
        }
        return nil
    }

    private static func candidatePaths(for strippedPath: String, relativeToMarkdownFile markdownFilePath: String) -> [String] {
        if let url = URL(string: strippedPath), let scheme = url.scheme?.lowercased() {
            if scheme == "file" {
                return [url.path]
            }
            if let relativePath = webKitCoercedRelativePath(from: url, scheme: scheme) {
                return relativeCandidatePaths(relativePath, relativeToMarkdownFile: markdownFilePath)
            }
            if shouldTreatUnknownSchemeAsRelativePath(strippedPath, scheme: scheme) {
                return relativeCandidatePaths(strippedPath, relativeToMarkdownFile: markdownFilePath)
            }
            return []
        }
        if (strippedPath as NSString).isAbsolutePath {
            return [strippedPath]
        }
        return relativeCandidatePaths(strippedPath, relativeToMarkdownFile: markdownFilePath)
    }

    private static func shouldTreatUnknownSchemeAsRelativePath(_ path: String, scheme: String) -> Bool {
        guard !knownExternalSchemes.contains(scheme) else { return false }
        let lowercasedPath = path.lowercased()
        return lowercasedPath.hasPrefix("\(scheme):") && !lowercasedPath.hasPrefix("\(scheme)://")
    }

    private static func relativeCandidatePaths(_ relativePath: String, relativeToMarkdownFile markdownFilePath: String) -> [String] {
        let markdownDir = (markdownFilePath as NSString).deletingLastPathComponent
        return [(markdownDir as NSString).appendingPathComponent(relativePath)]
    }

    private static func webKitCoercedRelativePath(from url: URL, scheme: String) -> String? {
        guard scheme == "http" || scheme == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              let host = url.host?.removingPercentEncoding,
              !host.isEmpty,
              host != "localhost",
              !host.contains("."),
              !host.contains(":") else {
            return nil
        }
        let path = url.path.removingPercentEncoding ?? url.path
        guard path.hasPrefix("/"), path.count > 1 else { return nil }
        return host + path
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
