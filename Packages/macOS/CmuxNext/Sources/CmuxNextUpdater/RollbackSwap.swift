public import Foundation
import CmuxNextCompat

/// Puts a kept build in place of the running one (decision 2026-10-04,
/// after ``RollbackDecision`` allowed it): the running build is kept first
/// (so the user can move forward again), then the kept bundle replaces it
/// by an atomic rename on the same volume.
nonisolated public struct RollbackSwap {
    public init() {}
    /// - Returns: the bundle now at `current`.
    @discardableResult
    public static func perform(current: URL, currentBuild: String, target: KeptVersion, store: KeptVersionStore, limit: Int) throws -> URL {
        // 1. Take the kept bundle out of the store, next to the running one.
        let staged = current.deletingLastPathComponent()
            .appending(path: ".cmux-rollback-\(UUID().uuidString)-\(current.lastPathComponent)", directoryHint: .isDirectory)
        try FileManager.checked.moveItem(at: target.bundle, to: staged)
        var keptCurrent = false
        do {
            // 2. Keep the running build, so the user can move forward again.
            try store.keep(bundle: current, build: currentBuild, limit: max(1, limit))
            keptCurrent = true
            // 3. Atomic swap on the same volume.
            _ = try FileManager.checked.replaceItemAt(current, withItemAt: staged)
        } catch {
            // Put the kept build back where it was (its folder is still there): a failed swap
            // must not cost the user the only build they can drop back to, nor leave the
            // running build listed as a rollback target.
            try? FileManager.checked.moveItem(at: staged, to: target.bundle)
            if keptCurrent, currentBuild != target.build {
                try? FileManager.checked.removeItem(at: store.root.appending(path: currentBuild, directoryHint: .isDirectory))
            }
            throw error
        }
        // 4. The kept build's folder is empty now; it goes only after the swap succeeded.
        try? FileManager.checked.removeItem(at: target.bundle.deletingLastPathComponent())
        return current
    }

    /// The helper that reopens the app once `pid` has exited: `caffeinate -w`
    /// waits on the kernel's exit event (no polling), then `open` starts the
    /// swapped bundle.
    public static func relaunchCommand(pid: Int32, app: URL) -> [String] {
        ["/bin/sh", "-c", "/usr/bin/caffeinate -w \(pid); /usr/bin/open \"$0\"", app.path]
    }
}
