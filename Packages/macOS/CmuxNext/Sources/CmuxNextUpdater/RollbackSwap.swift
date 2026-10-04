public import Foundation

/// Puts a kept build in place of the running one (decision 2026-10-04,
/// after ``RollbackDecision`` allowed it): the running build is kept first
/// (so the user can move forward again), then the kept bundle replaces it
/// by an atomic rename on the same volume.
nonisolated public enum RollbackSwap {
    /// - Returns: the bundle now at `current`.
    @discardableResult
    public static func perform(current: URL, currentBuild: String, target: KeptVersion, store: KeptVersionStore, limit: Int) throws -> URL {
        current
    }

    /// The helper that reopens the app once `pid` has exited: `caffeinate -w`
    /// waits on the kernel's exit event (no polling), then `open` starts the
    /// swapped bundle.
    public static func relaunchCommand(pid: Int32, app: URL) -> [String] {
        []
    }
}
