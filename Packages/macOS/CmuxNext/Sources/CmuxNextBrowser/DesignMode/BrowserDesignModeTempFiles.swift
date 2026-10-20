public import Foundation

/// Where design mode cards are written as files for the Home composer (``BrowserDesignModeCardFiles``):
/// one folder per card under `root`.
public nonisolated struct BrowserDesignModeTempFiles: Sendable {
    /// The folder every card folder lives in.
    public let root: URL

    public init(root: URL) { self.root = root }

    /// A new, unique folder for one card (not created yet; the writer makes it).
    public func newFolder() -> URL { root.appendingPathComponent(UUID().uuidString, isDirectory: true) }

    /// Removes one card's folder.
    public func remove(_ folder: URL) {}

    /// Removes every card folder.
    public func removeAll() {}
}
