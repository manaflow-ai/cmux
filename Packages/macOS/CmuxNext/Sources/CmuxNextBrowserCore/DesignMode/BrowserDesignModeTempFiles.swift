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

    /// Removes every card folder (at quit, and at launch after a crash).
    public func removeAll() { try? FileManager.default.removeItem(at: root) }
}
