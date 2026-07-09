public import Foundation

extension URL {
    /// The directory WebKit should be granted read access to when loading this
    /// local file URL, or `nil` when the receiver is not a usable absolute file URL.
    ///
    /// For a directory the receiver itself is returned; for a file its parent
    /// directory is returned. Non-file URLs and relative paths yield `nil`.
    public func browserReadAccessURL(fileManager: FileManager = .default) -> URL? {
        guard isFileURL, path.hasPrefix("/") else { return nil }
        let path = self.path
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return self
        }

        let parent = deletingLastPathComponent()
        guard !parent.path.isEmpty, parent.path.hasPrefix("/") else { return nil }
        return parent
    }
}
