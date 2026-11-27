public import Foundation

/// Puts a kept build in place of the running one (decision 2026-10-04,
/// after ``RollbackDecision`` allowed it): the running build is kept first
/// (so the user can move forward again), then the kept bundle replaces it
/// by an atomic rename on the same volume.
nonisolated public struct RollbackSwap {
    public init() {}
    /// - Returns: the bundle now at `current`.
    @discardableResult
    public static func perform(current: URL, currentBuild: String, target: KeptVersion, store: KeptVersionStore, limit: Int) throws -> URL {
        let files = FileManager.default
        // 1. Take the kept bundle out of the store, next to the running one.
        let staged = current.deletingLastPathComponent()
            .appending(path: ".cmux-rollback-\(UUID().uuidString)-\(current.lastPathComponent)", directoryHint: .isDirectory)
        try files.moveItem(at: target.bundle, to: staged)
        var keptCurrent = false
        do {
            // 2. Keep the running build, so the user can move forward again.
            try store.keep(bundle: current, build: currentBuild, limit: max(1, limit))
            keptCurrent = true
            // 3. Atomic swap on the same volume. The kept bundle keeps its own metadata: copying
            // the running bundle's security and creation date onto it is what failed on a fleet
            // Mac (NSCocoaError 512 over POSIX EINTR, cmux#32624's proof), and a signed bundle
            // needs none of it.
            try Self.retryingInterrupted {
                _ = try files.replaceItemAt(current, withItemAt: staged, options: .usingNewMetadataOnly)
            }
        } catch {
            // Put the kept build back where it was (its folder is still there): a failed swap
            // must not cost the user the only build they can drop back to, nor leave the
            // running build listed as a rollback target.
            try? files.moveItem(at: staged, to: target.bundle)
            if keptCurrent, currentBuild != target.build {
                try? files.removeItem(at: store.root.appending(path: currentBuild, directoryHint: .isDirectory))
            }
            throw error
        }
        // 4. The kept build's folder is empty now; it goes only after the swap succeeded.
        try? files.removeItem(at: target.bundle.deletingLastPathComponent())
        return current
    }

    /// Runs `body` again when a signal interrupted its system call (EINTR anywhere in the error's
    /// underlying chain), at most `attempts` times; any other error is thrown at once.
    static func retryingInterrupted(attempts: Int = 4, _ body: () throws -> Void) throws {
        for _ in 1..<max(1, attempts) {
            do { return try body() } catch where interrupted(error) {}
        }
        try body()
    }

    static func interrupted(_ error: Error) -> Bool {
        var next: NSError? = error as NSError
        while let current = next {
            if current.domain == NSPOSIXErrorDomain, current.code == Int(EINTR) { return true }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// The helper that reopens the app once `pid` has exited: `caffeinate -w`
    /// waits on the kernel's exit event (no polling), then `open` starts the
    /// swapped bundle.
    public static func relaunchCommand(pid: Int32, app: URL) -> [String] {
        ["/bin/sh", "-c", "/usr/bin/caffeinate -w \(pid); /usr/bin/open \"$0\"", app.path]
    }
}
