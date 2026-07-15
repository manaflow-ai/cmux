internal import Foundation

// Safety: FileManager supports concurrent filesystem operations; both stored
// references are immutable and purge has no in-memory mutable state.
struct SentryCachePurger: @unchecked Sendable {
    private let fileManager: FileManager
    private let cachesDirectory: URL?

    init(
        fileManager: FileManager = FileManager(),
        cachesDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.cachesDirectory = cachesDirectory ?? fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first
    }

    /// Deletes Sentry's envelope cache and raw SentryCrash report store.
    func purge() {
        guard let cachesDirectory else { return }
        try? fileManager.removeItem(at: cachesDirectory.appendingPathComponent("io.sentry"))
        try? fileManager.removeItem(at: cachesDirectory.appendingPathComponent("SentryCrash"))
    }
}
