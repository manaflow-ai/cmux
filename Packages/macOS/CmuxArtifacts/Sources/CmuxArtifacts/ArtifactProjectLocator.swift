public import Foundation

/// Resolves the nearest project root from a working directory or file path.
public struct ArtifactProjectLocator: Sendable {
    /// Creates a project locator.
    public init() {}

    /// Finds the nearest ancestor containing `.cmux`, otherwise the nearest Git root.
    ///
    /// - Parameters:
    ///   - startingURL: Working directory or file URL.
    ///   - fileManager: Filesystem dependency used for testable lookup.
    /// - Returns: Project root, falling back to the starting directory.
    public func projectRoot(
        startingAt startingURL: URL,
        fileManager: FileManager
    ) -> URL {
        var isDirectory: ObjCBool = false
        let standardized = startingURL.standardizedFileURL
        let startingDirectory: URL
        if fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            startingDirectory = standardized.deletingLastPathComponent()
        } else {
            startingDirectory = standardized
        }
        for current in ArtifactAncestorDirectories(startingAt: startingDirectory) {
            if fileManager.fileExists(atPath: current.appendingPathComponent(".cmux", isDirectory: true).path) {
                return current
            }
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git", isDirectory: false).path) {
                return current
            }
        }
        return startingDirectory
    }
}
