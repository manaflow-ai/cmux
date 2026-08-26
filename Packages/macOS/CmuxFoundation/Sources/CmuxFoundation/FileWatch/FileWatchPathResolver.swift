import Foundation

/// Resolves the nearest safe existing directory for a watched path.
struct FileWatchPathResolver: Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func nearestExistingDirectory(
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
                guard allowsFilesystemRootAncestor || standardized != "/" else {
                    return nil
                }
                return standardized
            }
            let parent = (standardized as NSString).deletingLastPathComponent
            if parent == standardized || parent.isEmpty { break }
            current = parent
        }
        let fallback = (fileManager.currentDirectoryPath as NSString).standardizingPath
        return allowsFilesystemRootAncestor || fallback != "/" ? fallback : nil
    }
}
