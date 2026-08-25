import Foundation

/// The filesystem seam used to identify a repository's reference backend.
nonisolated protocol GitReferenceStorageProbing: Sendable {
    /// Returns whether `path` currently resolves to a directory.
    func isDirectory(atPath path: String) -> Bool
}

/// Probes reference-storage directories through Foundation's filesystem API.
nonisolated struct SystemGitReferenceStorageProbe: GitReferenceStorageProbing {
    func isDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
