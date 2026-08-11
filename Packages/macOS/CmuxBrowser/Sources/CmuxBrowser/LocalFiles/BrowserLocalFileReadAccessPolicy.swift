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

    /// Returns containing-directory read access for an unvalidated local URL.
    ///
    /// ``fileOnly`` deliberately returns `nil`; those callers must resolve and
    /// validate through the bounded filesystem probe, then call
    /// ``readAccessURL(forResolvedNavigationURL:)``.
    ///
    /// - Parameters:
    ///   - fileURL: The local document or directory URL being loaded.
    ///   - fileManager: The filesystem accessor used to distinguish files from directories.
    /// - Returns: The permitted read-access URL, or `nil` when this policy rejects the URL.
    public func readAccessURL(
        for fileURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        // File-only callers must use the deadline-bounded regular-file probe,
        // then pass its canonical result to the resolved-URL overload. Keeping
        // this synchronous path exclusive to the legacy directory policy
        // prevents a main-actor caller from resolving a stalled symlink mount.
        guard self == .containingDirectory,
              fileURL.browserIsLocalFileURL,
              fileURL.path.hasPrefix("/") else {
            return nil
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: fileURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            return fileURL
        }
        let parent = fileURL.deletingLastPathComponent()
        guard !parent.path.isEmpty, parent.path.hasPrefix("/") else { return nil }
        return parent
    }
}
