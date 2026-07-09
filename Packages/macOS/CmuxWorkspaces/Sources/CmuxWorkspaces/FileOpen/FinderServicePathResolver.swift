public import Foundation

/// Pure URL/path deduplication and ordering for external-open file URLs,
/// lifted byte-faithfully from the legacy app-target
/// `FinderServicePathResolver` namespace enum.
///
/// This is a real `Sendable` value type, not a static namespace: callers
/// construct an instance and invoke the rules through it. The transforms are
/// pure functions of their arguments (URL standardization, symlink
/// resolution, and `.isDirectoryKey` resource reads), so the type carries no
/// stored state and crosses isolation domains safely.
///
/// `ExternalOpenURLClassifier` injects ``orderedUniqueDirectories(from:excludingDescendantsOf:)``
/// as its directory-ordering closure, keeping this resolver the single source
/// of truth for that rule.
public struct FinderServicePathResolver: Sendable {
    /// Creates a resolver.
    public init() {}

    private func canonicalDirectoryPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var canonical = path
        while canonical.count > 1 && canonical.hasSuffix("/") {
            canonical.removeLast()
        }
        return canonical
    }

    private func normalizedComparisonURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isSameOrDescendant(_ url: URL, of rootURL: URL) -> Bool {
        let urlPathComponents = normalizedComparisonURL(url).pathComponents
        let rootPathComponents = normalizedComparisonURL(rootURL).pathComponents
        guard urlPathComponents.count >= rootPathComponents.count else { return false }
        return Array(urlPathComponents.prefix(rootPathComponents.count)) == rootPathComponents
    }

    private func resolvedDirectoryURL(from url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if standardized.hasDirectoryPath {
            return standardized
        }
        if let resourceValues = try? standardized.resourceValues(forKeys: [.isDirectoryKey]),
           resourceValues.isDirectory == true {
            return standardized
        }
        return standardized.deletingLastPathComponent()
    }

    /// Returns the ordered, unique parent directories of the given file URLs,
    /// excluding any directory that is the same as or a descendant of one of
    /// `excludedRootURLs`. Files contribute their containing directory;
    /// directories contribute themselves. Order follows first appearance;
    /// duplicates are collapsed by symlink-resolved path.
    public func orderedUniqueDirectories(
        from pathURLs: [URL],
        excludingDescendantsOf excludedRootURLs: [URL] = []
    ) -> [String] {
        var seen: Set<String> = []
        var directories: [String] = []

        for url in pathURLs {
            let directoryURL = resolvedDirectoryURL(from: url)
            guard !excludedRootURLs.contains(where: { isSameOrDescendant(directoryURL, of: $0) }) else {
                continue
            }
            let path = canonicalDirectoryPath(directoryURL.path(percentEncoded: false))
            let dedupePath = canonicalDirectoryPath(
                normalizedComparisonURL(directoryURL).path(percentEncoded: false)
            )
            guard !path.isEmpty, !dedupePath.isEmpty else { continue }
            if seen.insert(dedupePath).inserted {
                directories.append(path)
            }
        }

        return directories
    }
}
