import CmuxNextCompat
public import Foundation

/// Where design mode cards are written as files for the Home composer (``BrowserDesignModeCardFiles``):
/// one folder per launch under `root`, one folder per card in it. The launch cleanup of what earlier
/// launches left (a crash) runs when it is convenient and never takes this launch's cards.
public nonisolated struct BrowserDesignModeTempFiles: Sendable {
    /// The folder every launch's folder lives in.
    public let root: URL
    /// This launch's folder; its card folders live here.
    public let run: URL

    /// - Parameters:
    ///   - root: The folder every launch's folder lives in.
    ///   - run: The name of this launch's folder in `root`.
    public init(root: URL, run: String = UUID().uuidString) {
        self.root = root
        self.run = root.appendingPathComponent(run, isDirectory: true)
    }

    /// A new, unique folder for one card (not created yet; the writer makes it).
    public func newFolder() -> URL { run.appendingPathComponent(UUID().uuidString, isDirectory: true) }

    /// Removes one card's folder; a folder outside this launch's folder is left alone.
    public func remove(_ folder: URL) {
        let base = run.standardizedFileURL.path + "/"
        guard folder.standardizedFileURL.path.hasPrefix(base) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes every card folder of this launch (at quit).
    public func removeAll() { try? FileManager.default.removeItem(at: run) }

    /// Removes what earlier launches left in `root` (after a crash): everything but this launch's folder.
    /// Disk I/O: call it off the main thread (the launch posts it on the files lane).
    public func removeEarlierRuns() {
        guard let entries = try? FileManager.checked.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent != run.lastPathComponent {
            try? FileManager.checked.removeItem(at: entry)
        }
    }
}
