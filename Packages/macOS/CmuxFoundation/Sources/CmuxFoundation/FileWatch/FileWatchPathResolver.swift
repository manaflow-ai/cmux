import Foundation

/// Resolves the nearest safe existing directory for a watched path.
public struct FileWatchPathResolver: Sendable {
    private let fileManager: FileManager

    /// Creates a resolver with an injectable filesystem provider.
    public init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    /// The home directory reported by the injected filesystem provider.
    public var homeDirectoryPath: String {
        fileManager.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .deletingLastPathComponent()
            .standardizedFileURL
            .path ?? "/"
    }

    /// Returns the nearest existing directory for a path.
    public func nearestExistingDirectory(
        forPath path: String,
        allowsFilesystemRootAncestor: Bool
    ) -> String? {
        var current = (path as NSString).deletingLastPathComponent
        var seen = Set<String>()
        while !current.isEmpty {
            let standardized = (current as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { break }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
               isDirectory.boolValue {
                guard !allowsFilesystemRootAncestor else {
                    return standardized
                }
                let resolved = URL(fileURLWithPath: standardized)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                    .path
                return resolved == "/" ? nil : resolved
            }
            let parent = (standardized as NSString).deletingLastPathComponent
            if parent == standardized || parent.isEmpty { break }
            current = parent
        }
        let fallback = (fileManager.currentDirectoryPath as NSString).standardizingPath
        guard !allowsFilesystemRootAncestor else { return fallback }
        let resolvedFallback = URL(fileURLWithPath: fallback)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return resolvedFallback == "/" ? nil : resolvedFallback
    }
}
