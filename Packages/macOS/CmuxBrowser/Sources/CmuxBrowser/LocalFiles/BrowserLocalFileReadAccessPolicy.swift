public import Foundation

/// Defines the local filesystem scope granted to a Browser navigation.
public enum BrowserLocalFileReadAccessPolicy: String, Codable, Equatable, Hashable, Sendable {
    /// Grants the displayed file access to other files in its containing directory.
    case containingDirectory
    /// Grants access only to the displayed file after resolving its canonical target.
    case fileOnly

    /// Resolves the document URL required by this policy.
    public func resolvedNavigationURL(for url: URL) -> URL {
        guard self == .fileOnly, url.isFileURL else { return url }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Returns the narrowest WebKit read-access URL permitted by this policy.
    public func readAccessURL(
        for fileURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/") else { return nil }
        let resolvedURL = resolvedNavigationURL(for: fileURL)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: resolvedURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            return self == .fileOnly ? nil : resolvedURL
        }

        switch self {
        case .fileOnly:
            return resolvedURL
        case .containingDirectory:
            let parent = resolvedURL.deletingLastPathComponent()
            guard !parent.path.isEmpty, parent.path.hasPrefix("/") else { return nil }
            return parent
        }
    }
}
