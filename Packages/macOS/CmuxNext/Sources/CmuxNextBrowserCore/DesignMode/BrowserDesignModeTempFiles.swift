import CmuxNextCompat
public import Foundation

/// Where design mode cards are written as files for the Home composer (``BrowserDesignModeCardFiles``):
/// one folder per card under `root`.
public nonisolated struct BrowserDesignModeTempFiles: Sendable {
    /// The folder every card folder lives in.
    public let root: URL

    public init(root: URL) { self.root = root }

    /// A new, unique folder for one card (not created yet; the writer makes it).
    public func newFolder() -> URL { root.appendingPathComponent(UUID().uuidString, isDirectory: true) }

    /// Removes one card's folder; a folder outside ``root`` is left alone.
    public func remove(_ folder: URL) {
        let base = root.standardizedFileURL.path + "/"
        guard folder.standardizedFileURL.path.hasPrefix(base) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// After the first frame, remove only card folders that predate this launch.
    /// A card the person has just attached can already be waiting for the composer to copy its files.
    public func removeLeftovers(before launch: Date) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]
        let manager = FileManager.checked
        guard (try? root.blockingResourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false,
              let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return }
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            guard let values = try? folder.blockingResourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink == false,
                  let created = values.creationDate, created < launch else { continue }
            try? manager.removeItem(at: folder)
        }
    }

    /// Removes every card folder at quit.
    public func removeAll() { try? FileManager.default.removeItem(at: root) }
}
