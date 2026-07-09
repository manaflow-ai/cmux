public import Foundation

extension URL {
    /// Normalized form of a trusted local file URL used for identity comparison:
    /// `nil` unless this is a file URL, otherwise standardized with symlinks resolved.
    public var normalizedTrustedFileURL: URL? {
        guard isFileURL else {
            return nil
        }
        return standardizedFileURL.resolvingSymlinksInPath()
    }

    /// True when this URL and `expected` normalize to the same trusted shell file URL.
    ///
    /// Returns `false` when either side is not a file URL.
    public func isTrustedShellURL(expected: URL?) -> Bool {
        guard let candidate = normalizedTrustedFileURL,
              let expected = expected?.normalizedTrustedFileURL else {
            return false
        }
        return candidate == expected
    }

    /// True when navigating to this URL is an in-page fragment relative to `currentURL`
    /// (same document, only the fragment differs), so the navigation should be allowed
    /// in place rather than opened externally.
    public func isInPageFragment(currentURL: URL?) -> Bool {
        guard fragment != nil else { return false }
        if (scheme == nil || scheme == "about"), (host ?? "").isEmpty {
            return true
        }
        guard let currentURL else { return false }
        if isFileURL, currentURL.isFileURL {
            return (path as NSString).standardizingPath ==
                (currentURL.path as NSString).standardizingPath
        }
        return scheme == currentURL.scheme &&
            host == currentURL.host &&
            path == currentURL.path
    }
}
