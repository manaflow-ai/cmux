import Foundation

/// Pure path-scope checker for artifacts referenced by a chat transcript.
///
/// The checker canonicalizes transcript-referenced paths and requested paths
/// through an injected resolver, then answers whether a request may stat,
/// fetch, thumbnail, or list a path without touching the requested path's
/// filesystem metadata. Exact referenced paths are always allowed. Descendants
/// of referenced directories follow the configured ``DirectoryAccessMode``.
public struct ChatArtifactScope: Sendable {
    /// How referenced directories authorize descendant paths.
    public enum DirectoryAccessMode: String, Sendable {
        /// Authorize every canonical descendant of a referenced directory.
        case subtree
        /// Authorize immediate children for file operations and only the
        /// referenced directory itself for listing, matching the legacy rule.
        case oneLevel
    }

    /// Filesystem operations needed to canonicalize and classify referenced paths.
    public protocol FileSystemResolving: Sendable {
        /// Resolves symlinks in a path and returns a filesystem path string.
        ///
        /// - Parameter path: Absolute path to resolve.
        /// - Returns: The resolved path, or `nil` when resolution fails.
        func resolveSymlinks(of path: String) -> String?

        /// Reports whether a path is a directory.
        ///
        /// - Parameter path: Absolute path to inspect.
        /// - Returns: `true` for a directory, `false` for a non-directory, or
        ///   `nil` when the path cannot be inspected.
        func isDirectory(_ path: String) -> Bool?
    }

    /// Foundation-backed resolver used by production Mac artifact handlers.
    public struct FoundationResolver: FileSystemResolving {
        /// Creates a Foundation-backed resolver.
        public init() {}

        public func resolveSymlinks(of path: String) -> String? {
            URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        }

        public func isDirectory(_ path: String) -> Bool? {
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return nil
            }
            return isDirectory.boolValue
        }
    }

    private struct ReferencedPath: Sendable, Hashable {
        let canonicalPath: String
        let isDirectory: Bool?
    }

    private static let maximumPathLength = 4096

    private let referencedCanonicalPaths: Set<String>
    private let referencedDirectoryCanonicalPaths: Set<String>
    private let directoryAccessMode: DirectoryAccessMode
    private let resolver: any FileSystemResolving

    /// Creates a scope checker from transcript-referenced path strings.
    ///
    /// - Parameters:
    ///   - referencedPaths: Paths as they appeared in the transcript.
    ///   - directoryAccessMode: Descendant authorization policy. The default
    ///     preserves the legacy one-level behavior for existing callers.
    ///   - resolver: Filesystem resolver used for canonicalization.
    public init(
        referencedPaths: Set<String>,
        directoryAccessMode: DirectoryAccessMode = .oneLevel,
        resolver: any FileSystemResolving
    ) {
        self.resolver = resolver
        self.directoryAccessMode = directoryAccessMode
        let canonical = referencedPaths.compactMap { path -> ReferencedPath? in
            guard let canonicalPath = Self.canonicalPath(path, resolver: resolver) else {
                return nil
            }
            return ReferencedPath(
                canonicalPath: canonicalPath,
                isDirectory: resolver.isDirectory(canonicalPath)
            )
        }
        self.referencedCanonicalPaths = Set(canonical.map(\.canonicalPath))
        self.referencedDirectoryCanonicalPaths = Set(
            canonical.compactMap { $0.isDirectory == true ? $0.canonicalPath : nil }
        )
    }

    /// Resolves an allowed file/stat/thumbnail request to its canonical path.
    ///
    /// - Parameter path: Requested absolute path.
    /// - Returns: Canonical path when the request is in scope, otherwise `nil`.
    public func canonicalFilePath(for path: String) -> String? {
        guard let canonicalPath = Self.canonicalPath(path, resolver: resolver) else {
            return nil
        }
        if referencedCanonicalPaths.contains(canonicalPath) {
            return canonicalPath
        }
        switch directoryAccessMode {
        case .subtree:
            guard referencedDirectoryCanonicalPaths.contains(where: {
                Self.isCanonicalPath(canonicalPath, containedIn: $0)
            }) else {
                return nil
            }
        case .oneLevel:
            guard let parent = Self.parentPath(ofCanonicalPath: canonicalPath),
                  referencedDirectoryCanonicalPaths.contains(parent) else {
                return nil
            }
        }
        return canonicalPath
    }

    /// Canonicalizes one absolute path using the same symlink-resolution and
    /// standardization rules as scope checks.
    ///
    /// - Parameters:
    ///   - path: Absolute path to canonicalize.
    ///   - resolver: Filesystem resolver used for symlink resolution.
    /// - Returns: Canonical path, or `nil` for invalid/unresolvable paths.
    public static func canonicalizedPath(
        _ path: String,
        resolver: any FileSystemResolving
    ) -> String? {
        canonicalPath(path, resolver: resolver)
    }

    /// Resolves an allowed directory-list request to its canonical path.
    ///
    /// - Parameter path: Requested absolute directory path.
    /// - Returns: Canonical path when the directory itself was referenced, or
    ///   when subtree access permits the canonical descendant; otherwise `nil`.
    public func canonicalDirectoryListPath(for path: String) -> String? {
        guard let canonicalPath = Self.canonicalPath(path, resolver: resolver) else {
            return nil
        }
        if referencedCanonicalPaths.contains(canonicalPath) {
            return canonicalPath
        }
        guard directoryAccessMode == .subtree,
              referencedDirectoryCanonicalPaths.contains(where: {
                  Self.isCanonicalPath(canonicalPath, containedIn: $0)
              }) else {
            return nil
        }
        return canonicalPath
    }

    private static func canonicalPath(
        _ path: String,
        resolver: any FileSystemResolving
    ) -> String? {
        guard isValidAbsolutePath(path),
              let resolved = resolver.resolveSymlinks(of: path),
              isValidAbsolutePath(resolved)
        else {
            return nil
        }
        let standardized = (resolved as NSString).standardizingPath
        guard isValidAbsolutePath(standardized) else {
            return nil
        }
        return standardized
    }

    private static func isValidAbsolutePath(_ path: String) -> Bool {
        !path.isEmpty
            && path.count <= maximumPathLength
            && path.hasPrefix("/")
    }

    private static func parentPath(ofCanonicalPath path: String) -> String? {
        guard path != "/" else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty {
            return "/"
        }
        return parent
    }

    /// Tests containment only after both inputs have been canonicalized.
    private static func isCanonicalPath(_ path: String, containedIn directory: String) -> Bool {
        guard path != directory else { return true }
        let prefix = directory == "/" ? "/" : "\(directory)/"
        return path.hasPrefix(prefix)
    }
}
