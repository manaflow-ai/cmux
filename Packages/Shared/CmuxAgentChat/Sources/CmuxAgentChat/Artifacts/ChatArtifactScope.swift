import Foundation

/// Pure path-scope checker for artifacts referenced by a chat transcript.
///
/// The checker canonicalizes transcript-referenced paths and requested paths
/// through an injected resolver, then answers whether a request may stat,
/// fetch, thumbnail, or list a path without touching the requested path's
/// filesystem metadata. File operations are allowed for exact referenced
/// paths and for one immediate child of a referenced directory. Directory
/// listing is allowed only for directories that were themselves referenced.
public struct ChatArtifactScope: Sendable {
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

    private let referencedPaths: Set<ReferencedPath>
    private let referencedCanonicalPaths: Set<String>
    private let referencedDirectoryCanonicalPaths: Set<String>
    private let resolver: any FileSystemResolving

    /// Creates a scope checker from transcript-referenced path strings.
    ///
    /// - Parameters:
    ///   - referencedPaths: Paths as they appeared in the transcript.
    ///   - resolver: Filesystem resolver used for canonicalization.
    public init(
        referencedPaths: Set<String>,
        resolver: any FileSystemResolving
    ) {
        self.resolver = resolver
        let canonical = referencedPaths.compactMap { path -> ReferencedPath? in
            guard let canonicalPath = Self.canonicalPath(path, resolver: resolver) else {
                return nil
            }
            return ReferencedPath(
                canonicalPath: canonicalPath,
                isDirectory: resolver.isDirectory(canonicalPath)
            )
        }
        self.referencedPaths = Set(canonical)
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
        guard let parent = Self.parentPath(ofCanonicalPath: canonicalPath),
              referencedDirectoryCanonicalPaths.contains(parent)
        else {
            return nil
        }
        return canonicalPath
    }

    /// Resolves an allowed directory-list request to its canonical path.
    ///
    /// - Parameter path: Requested absolute directory path.
    /// - Returns: Canonical path when the directory itself was referenced,
    ///   otherwise `nil`.
    public func canonicalDirectoryListPath(for path: String) -> String? {
        guard let canonicalPath = Self.canonicalPath(path, resolver: resolver),
              referencedPaths.contains(ReferencedPath(canonicalPath: canonicalPath, isDirectory: true))
        else {
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
}
