public import Foundation

/// Puts a kept build in place of the running one (decision 2026-10-04,
/// after ``RollbackDecision`` allowed it): the running build is kept first
/// (so the user can move forward again), then the kept bundle replaces it
/// by an atomic rename on the same volume.
nonisolated public struct RollbackSwap {
    public init() {}
    /// - Returns: the bundle now at `current`.
    @discardableResult
    public static func perform(current: URL, currentBuild: String, target: KeptVersion, store: KeptVersionStore, limit: Int,
                               record: KeptRecord? = nil) throws -> URL {
        let files = FileManager.default
        // 1. Take the kept bundle out of the store, next to the running one.
        let staged = current.deletingLastPathComponent()
            .appending(path: "\(stagedPrefix)\(target.build)-\(UUID().uuidString)-\(current.lastPathComponent)", directoryHint: .isDirectory)
        try files.moveItem(at: target.bundle, to: staged)
        var keptCurrent = false
        do {
            // 2. Keep the running build, so the user can move forward again.
            try store.keep(bundle: current, build: currentBuild, limit: max(1, limit), record: record)
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

    /// The name a kept bundle has while it stands beside the running one, mid-swap:
    /// `.cmux-rollback-<build>-<uuid>-<App>.app`.
    static let stagedPrefix = ".cmux-rollback-"

    /// Puts back a kept bundle a swap left beside `current` (the app was killed or the Mac lost
    /// power between taking it out of the store and the rename): into the store under its build
    /// when that build has no app there, else it goes (the store has it). A name from before the
    /// build was in it (`.cmux-rollback-<uuid>-...`) cannot say its build and goes. Returns what it
    /// tidied.
    public static func recover(current: URL, store: KeptVersionStore) -> [String] {
        let files = FileManager.default
        let folder = current.deletingLastPathComponent()
        guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { return [] }
        var tidied: [String] = []
        for name in names where name.hasPrefix(stagedPrefix) && name.hasSuffix(".app") {
            let staged = folder.appending(path: name, directoryHint: .isDirectory)
            let info = NSDictionary(contentsOf: staged.appending(path: "Contents/Info.plist")) as? [String: Any]
            let build = info?["CFBundleVersion"] as? String
            let home = build.map { store.root.appending(path: $0, directoryHint: .isDirectory) }
            let app = home?.appending(path: current.lastPathComponent, directoryHint: .isDirectory)
            if let home, let app, !files.fileExists(atPath: app.path),
               (try? files.createDirectory(at: home, withIntermediateDirectories: true)) != nil,
               (try? files.moveItem(at: staged, to: app)) != nil {
                tidied.append("put back \(build ?? name)")
                continue
            }
            try? files.removeItem(at: staged)
            tidied.append("removed \(name)")
        }
        return tidied
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
