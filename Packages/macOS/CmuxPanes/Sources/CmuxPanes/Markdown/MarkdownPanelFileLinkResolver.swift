public import Foundation

/// Resolves authored Markdown-panel links to existing local files.
///
/// The file-system dependency and fallback directory are supplied by the
/// owning panel so callers can preserve workspace-root fallback behavior
/// without relying on process-global state inside the resolver.
public struct MarkdownPanelFileLinkResolver {
    private let fileManager: FileManager
    private let fallbackDirectoryPath: String

    /// Creates a resolver for one panel-owner context.
    ///
    /// - Parameters:
    ///   - fileManager: The file manager used to check candidate files.
    ///   - fallbackDirectoryPath: The workspace or process-working-directory
    ///     root checked after the directory containing the Markdown file.
    public init(fileManager: FileManager, fallbackDirectoryPath: String) {
        self.fileManager = fileManager
        self.fallbackDirectoryPath = fallbackDirectoryPath
    }

    /// Resolves an authored link when it identifies an existing Markdown file.
    ///
    /// - Parameters:
    ///   - rawPath: The authored link destination.
    ///   - markdownFilePath: The absolute path of the containing Markdown file.
    /// - Returns: The standardized local path, or `nil` when the link is
    ///   remote, missing, a directory, or not Markdown.
    public func resolve(rawPath: String, relativeToMarkdownFile markdownFilePath: String) -> String? {
        guard let localFile = resolveLocalFile(rawPath: rawPath, relativeToMarkdownFile: markdownFilePath),
              MarkdownLinkPath(localFile).isMarkdownFile else {
            return nil
        }
        return localFile
    }

    /// Resolves an authored link when it identifies any existing local file.
    ///
    /// - Parameters:
    ///   - rawPath: The authored link destination.
    ///   - markdownFilePath: The absolute path of the containing Markdown file.
    /// - Returns: The standardized local path, or `nil` when the link is
    ///   remote, missing, or a directory.
    public func resolveLocalFile(rawPath: String, relativeToMarkdownFile markdownFilePath: String) -> String? {
        let stripped = MarkdownLinkPath(rawPath).pathWithoutQueryOrFragment
        guard !stripped.isEmpty else { return nil }

        for path in candidatePaths(for: stripped, relativeToMarkdownFile: markdownFilePath) {
            let standardized = (path as NSString).standardizingPath
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: standardized, isDirectory: &isDir), !isDir.boolValue {
                return standardized
            }
        }
        return nil
    }

    private func candidatePaths(
        for strippedPath: String,
        relativeToMarkdownFile markdownFilePath: String
    ) -> [String] {
        if let url = URL(string: strippedPath), let scheme = url.scheme?.lowercased() {
            if scheme == "file" {
                return [url.path]
            }
            return []
        }
        if (strippedPath as NSString).isAbsolutePath {
            return [strippedPath]
        }
        return relativeCandidatePaths(strippedPath, relativeToMarkdownFile: markdownFilePath)
    }

    private func relativeCandidatePaths(
        _ relativePath: String,
        relativeToMarkdownFile markdownFilePath: String
    ) -> [String] {
        let markdownDir = (markdownFilePath as NSString).deletingLastPathComponent
        return [
            (markdownDir as NSString).appendingPathComponent(relativePath),
            (fallbackDirectoryPath as NSString).appendingPathComponent(relativePath)
        ]
    }
}
