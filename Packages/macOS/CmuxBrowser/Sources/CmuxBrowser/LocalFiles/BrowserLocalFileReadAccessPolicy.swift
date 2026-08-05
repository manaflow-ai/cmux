public import Foundation

/// Browser-specific validation for local file URL authorities.
public extension URL {
    /// Whether this file URL names the local machine rather than a remote authority.
    var browserIsLocalFileURL: Bool {
        guard isFileURL else { return false }
        guard let host, !host.isEmpty else { return true }
        return host.caseInsensitiveCompare("localhost") == .orderedSame
    }
}

/// Defines the local filesystem scope granted to a Browser navigation.
public enum BrowserLocalFileReadAccessPolicy: String, Codable, Equatable, Hashable, Sendable {
    /// Grants the displayed file access to other files in its containing directory.
    case containingDirectory
    /// Grants access only to the displayed file after resolving its canonical target.
    case fileOnly

    /// Resolves the document URL required by this policy.
    ///
    /// - Parameter url: The navigation URL to resolve.
    /// - Returns: The canonical file target for ``fileOnly``, or the original URL otherwise.
    public func resolvedNavigationURL(for url: URL) -> URL {
        guard self == .fileOnly, url.browserIsLocalFileURL else { return url }
        let resolvedFileURL = URL(fileURLWithPath: url.path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return navigationURL(
            for: url,
            resolvedFileURL: resolvedFileURL
        ) ?? resolvedFileURL
    }

    /// Builds a navigation URL from a filesystem target that was resolved off
    /// the main actor, while preserving the original query and fragment.
    ///
    /// This method performs lexical URL work only. `resolvedFileURL` must be a
    /// path-only canonical file URL supplied by a deadline-bounded resolver.
    public func navigationURL(
        for originalURL: URL,
        resolvedFileURL: URL
    ) -> URL? {
        guard originalURL.browserIsLocalFileURL,
              resolvedFileURL.browserIsLocalFileURL,
              resolvedFileURL.path.hasPrefix("/"),
              let originalComponents = URLComponents(
                  url: originalURL,
                  resolvingAgainstBaseURL: false
              ),
              var resolvedComponents = URLComponents(
                  url: resolvedFileURL,
                  resolvingAgainstBaseURL: false
              ) else {
            return nil
        }
        resolvedComponents.percentEncodedQuery = originalComponents.percentEncodedQuery
        resolvedComponents.percentEncodedFragment = originalComponents.percentEncodedFragment
        return resolvedComponents.url
    }

    /// Returns path-only read access for a file URL already resolved off the
    /// main actor.
    public func readAccessURL(forResolvedNavigationURL fileURL: URL) -> URL? {
        guard self == .fileOnly,
              fileURL.browserIsLocalFileURL,
              fileURL.path.hasPrefix("/"),
              var components = URLComponents(
                  url: fileURL,
                  resolvingAgainstBaseURL: false
              ) else {
            return nil
        }
        components.percentEncodedQuery = nil
        components.percentEncodedFragment = nil
        return components.url
    }

    /// Returns the narrowest WebKit read-access URL permitted by this policy.
    ///
    /// - Parameters:
    ///   - fileURL: The local document or directory URL being loaded.
    ///   - fileManager: The filesystem accessor used to distinguish files from directories.
    /// - Returns: The permitted read-access URL, or `nil` when this policy rejects the URL.
    public func readAccessURL(
        for fileURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard fileURL.browserIsLocalFileURL, fileURL.path.hasPrefix("/") else { return nil }
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
