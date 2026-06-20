public import Foundation

/// Pure classifier for external-open file URLs, lifted byte-faithfully from
/// the legacy `AppDelegate.externalOpen*` helpers.
///
/// This is a real instance type (not a static namespace): the two ambient
/// inputs the legacy code read globally are constructor-injected so the rules
/// stay testable and the type carries no hidden global state —
/// `bundleURL` (the legacy `Bundle.main.bundleURL`, used to drop self-bundle
/// paths) and `orderedUniqueDirectories` (the legacy
/// `FinderServicePathResolver.orderedUniqueDirectories(from:excludingDescendantsOf:)`,
/// injected as a function value so that resolver stays the single source of
/// truth and is not duplicated here).
///
/// Sendable: the injected closure is `@Sendable`, and `bundleURL` is a value,
/// so the classifier crosses isolation domains safely.
public struct ExternalOpenURLClassifier: ExternalOpenURLClassifying {
    private let bundleURL: URL
    private let orderedUniqueDirectories: @Sendable (_ pathURLs: [URL], _ excludedRootURLs: [URL]) -> [String]

    /// Creates a classifier with explicit inputs.
    ///
    /// - Parameters:
    ///   - bundleURL: The running app bundle URL; descendants of it are
    ///     excluded from both directory and file results.
    ///   - orderedUniqueDirectories: Resolves ordered, unique directory paths
    ///     from file URLs, excluding descendants of the given roots. The app
    ///     injects `FinderServicePathResolver.orderedUniqueDirectories` so the
    ///     resolver remains the single source of truth.
    public init(
        bundleURL: URL,
        orderedUniqueDirectories: @escaping @Sendable (_ pathURLs: [URL], _ excludedRootURLs: [URL]) -> [String]
    ) {
        self.bundleURL = bundleURL
        self.orderedUniqueDirectories = orderedUniqueDirectories
    }

    public func directories(from urls: [URL]) -> [String] {
        // LaunchServices can surface the running app bundle on relaunch; ignore self paths so
        // they do not get treated as explicit folder opens and suppress session restore.
        orderedUniqueDirectories(
            urls.filter { $0.isFileURL },
            [bundleURL]
        )
    }

    public func fileURLs(from urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var fileURLs: [URL] = []
        for url in urls where url.isFileURL && !isDirectory(url) {
            let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !isDescendantOfBundle(standardized) else { continue }
            let path = standardized.path(percentEncoded: false)
            guard seen.insert(path).inserted else { continue }
            fileURLs.append(url.standardizedFileURL)
        }
        return fileURLs
    }

    public func isDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if url.hasDirectoryPath {
            return true
        }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isDescendantOfBundle(_ url: URL) -> Bool {
        let pathComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let bundleComponents = bundleURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard pathComponents.count >= bundleComponents.count else { return false }
        return Array(pathComponents.prefix(bundleComponents.count)) == bundleComponents
    }
}
