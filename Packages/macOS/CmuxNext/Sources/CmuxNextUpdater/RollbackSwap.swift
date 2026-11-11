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
        // 0. Still the bundle the click checked: its seal again, right before the rename (a change
        // between the check and the swap would otherwise run).
        guard store.stillSealed(target) else { throw Changed(build: target.build) }
        // 1. Take the kept bundle out of the store, next to the running one.
        let staged = current.deletingLastPathComponent()
            .appending(path: "\(stagedPrefix)\(target.build)-\(UUID().uuidString)-\(current.lastPathComponent)", directoryHint: .isDirectory)
        try files.moveItem(at: target.bundle, to: staged)
        var keptCurrent = false
        do {
            // 2. Keep the running build, so the user can move forward again.
            // At the click: the full check of this copy waits for the next launch (sealPending).
            try store.keep(bundle: current, build: currentBuild, limit: max(1, limit), record: record, check: .later)
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

    /// Puts the build that was running back in place after a rollback's quit was refused (a quit
    /// dialog's Cancel; cmux#41013 review F3). The app goes on running, so its own bundle must be
    /// the one on disk again. The kept build goes back to the store with its record (`targetRecord`,
    /// read before the swap), so Go back offers it as before.
    public static func undo(current: URL, runningBuild: String, target: KeptVersion, targetRecord: KeptRecord?,
                            store: KeptVersionStore) throws {
        let files = FileManager.checked
        let name = current.lastPathComponent, folder = current.deletingLastPathComponent()
        let keptRunningFolder = store.root.appending(path: runningBuild, directoryHint: .isDirectory)
        let keptRunning = keptRunningFolder.appending(path: name, directoryHint: .isDirectory)
        // 1. The running build's copy (kept at the click) comes out of the store, beside the app.
        let staged = folder.appending(path: "\(stagedPrefix)\(runningBuild)-\(UUID().uuidString)-\(name)", directoryHint: .isDirectory)
        try files.moveItem(at: keptRunning, to: staged)
        // 2. Atomic swap back. The kept build waits beside the app under a staged name until step 3,
        // so a crash between the two leaves it where `recover(current:store:)` puts it back.
        let backup = "\(stagedPrefix)\(target.build)-\(UUID().uuidString)-\(name)"
        do {
            try Self.retryingInterrupted {
                _ = try files.replaceItemAt(current, withItemAt: staged, backupItemName: backup,
                                            options: [.usingNewMetadataOnly, .withoutDeletingBackupItem])
            }
        } catch {
            try? files.moveItem(at: staged, to: keptRunning)
            throw error
        }
        // 3. The kept build goes back to its folder in the store, with its record.
        let home = target.bundle.deletingLastPathComponent()
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        try files.moveItem(at: folder.appending(path: backup, directoryHint: .isDirectory), to: target.bundle)
        // The moves gave every item a new ctime, so the seal taken before the swap no longer matches and a
        // later Go back would refuse it as changed (cmux#41013 review). The bundle sat in the app's place
        // between the swap and the refusal, where anything could change it: it gets the full check of every
        // file again before it is sealed and signed. A bundle that fails it keeps no record, so a later Go
        // back checks every file at the click (and refuses it).
        let recordFile = home.appending(path: KeptVersionStore.recordName)
        if var record = targetRecord {
            if record.seal != nil, record.isAuthentic(key: store.recordKey()) {
                record.seal(target.bundle, check: .full, fullCheck: store.teamID, key: store.recordKey())
                if record.seal == nil {
                    try? files.removeItem(at: recordFile)
                    return
                }
            }
            try? record.save(to: recordFile)
        }
        // 4. The running build is running again: its copy's folder (only its record now) goes.
        try? files.removeItem(at: keptRunningFolder)
    }

    /// The kept bundle changed after the click checked it; nothing was swapped.
    struct Changed: Error, CustomStringConvertible {
        let build: String
        var description: String { "kept build \(build) changed since it was checked" }
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
