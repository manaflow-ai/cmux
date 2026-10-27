import CmuxNextCompat
public import Foundation

/// Where design mode cards are written as files for the Home composer (``BrowserDesignModeCardFiles``):
/// one folder per card under `root`, this launch's own folder under `base`. Each launch writes only
/// into its own folder, so the cleanup of what earlier launches left (``removeEarlierLaunches()``) can
/// run at any time without touching a card this launch is attaching.
public nonisolated struct BrowserDesignModeTempFiles: Sendable {
    /// The folder every launch's folder lives in.
    public let base: URL
    /// This launch's folder: every card folder it writes lives here.
    public let root: URL

    /// The files of launch `launch` (a name unique to this process, such as a UUID) under `base`.
    public init(base: URL, launch: String) {
        self.base = base
        root = base.appendingPathComponent(launch, isDirectory: true)
    }

    /// A new, unique folder for one card (not created yet; the writer makes it).
    public func newFolder() -> URL { root.appendingPathComponent(UUID().uuidString, isDirectory: true) }

    /// Removes one card's folder; a folder outside ``root`` is left alone.
    public func remove(_ folder: URL) {
        let base = root.standardizedFileURL.path + "/"
        guard folder.standardizedFileURL.path.hasPrefix(base) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes this launch's card folders (at quit).
    public func removeAll() { try? FileManager.default.removeItem(at: root) }

    /// Removes everything in ``base`` except this launch's ``root``: the folders a crash or a killed
    /// launch left (at launch, on a files lane; safe while this launch writes cards).
    public func removeEarlierLaunches() {
        let own = root.standardizedFileURL.path
        guard let entries = try? FileManager.checked.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.standardizedFileURL.path != own {
            try? FileManager.checked.removeItem(at: entry)
        }
    }
}
