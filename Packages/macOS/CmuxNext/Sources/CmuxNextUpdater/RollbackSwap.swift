public import Foundation

/// Puts a kept build in place of the running one (decision 2026-10-04,
/// after ``RollbackDecision`` allowed it): the running build is kept first
/// (so the user can move forward again), then the kept bundle replaces it
/// by an atomic rename on the same volume.
nonisolated public enum RollbackSwap {
    /// - Returns: the bundle now at `current`.
    @discardableResult
    public static func perform(current: URL, currentBuild: String, target: KeptVersion, store: KeptVersionStore, limit: Int) throws -> URL {
        let files = FileManager.default
        // 1. Take the kept bundle out of the store, next to the running one.
        let staged = current.deletingLastPathComponent()
            .appending(path: ".cmux-rollback-\(UUID().uuidString)-\(current.lastPathComponent)", directoryHint: .isDirectory)
        try files.moveItem(at: target.bundle, to: staged)
        try? files.removeItem(at: target.bundle.deletingLastPathComponent())
        do {
            // 2. Keep the running build, so the user can move forward again.
            try store.keep(bundle: current, build: currentBuild, limit: max(1, limit))
            // 3. Atomic swap on the same volume.
            _ = try files.replaceItemAt(current, withItemAt: staged)
        } catch {
            try? files.removeItem(at: staged)
            throw error
        }
        return current
    }

    /// The helper that reopens the app once `pid` has exited: `caffeinate -w`
    /// waits on the kernel's exit event (no polling), then `open` starts the
    /// swapped bundle.
    public static func relaunchCommand(pid: Int32, app: URL) -> [String] {
        ["/bin/sh", "-c", "/usr/bin/caffeinate -w \(pid); /usr/bin/open \"$0\"", app.path]
    }
}
