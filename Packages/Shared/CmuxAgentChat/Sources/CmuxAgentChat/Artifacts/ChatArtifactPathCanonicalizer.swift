import Foundation

/// Produces stable filesystem identity keys for lexically normalized artifact paths.
public struct ChatArtifactPathCanonicalizer: Sendable {
    private let implementation: @Sendable (String) -> String

    /// Creates a canonicalizer backed by the current filesystem.
    public init() {
        implementation = Self.foundationCanonicalPathKey
    }

    /// Creates a canonicalizer with an injected identity operation.
    ///
    /// - Parameter canonicalPathKey: An operation that maps one lexically
    ///   normalized path to its canonical identity key.
    public init(canonicalPathKey: @escaping @Sendable (String) -> String) {
        implementation = canonicalPathKey
    }

    /// Returns the canonical identity key for a lexically normalized path.
    ///
    /// Existing absolute paths resolve symlinks and use their on-disk case.
    /// Missing and relative paths remain unchanged so deleted or unresolved
    /// transcript artifacts stay visible.
    ///
    /// - Parameter path: An already-lexically-normalized artifact path.
    /// - Returns: The filesystem identity key, or `path` when it is absent.
    public func canonicalPathKey(for path: String) -> String {
        implementation(path)
    }

    private static func foundationCanonicalPathKey(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let sourceURL = URL(fileURLWithPath: path)
        guard (try? sourceURL.checkResourceIsReachable()) == true else {
            return path
        }
        let resolvedURL = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        if let values = try? resolvedURL.resourceValues(forKeys: [.canonicalPathKey]),
           let canonicalPath = values.canonicalPath,
           !canonicalPath.isEmpty {
            return canonicalPath
        }
        return resolvedURL.path
    }
}
