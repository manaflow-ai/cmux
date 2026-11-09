import Darwin
public import Foundation

/// The "last opened app" pointer: the absolute path of the `cmux` CLI of the
/// app the user opened last, in `~/Library/Application Support/cmux-next/last-app-cli`.
///
/// A `cmux` shim outside the app's terminals (the `reload.sh` dev shim) reads
/// it to run the CLI that matches the app, not an older installed one
/// (plans/cmux-next/version-skew.md). The app is its only writer, once at
/// launch: written to a temporary file in the same directory (mode 0600)
/// and renamed over the old pointer, so a reader never sees a partial path,
/// and a symlink put in its place is replaced, never followed. An isolated
/// agent launch (`CMUX_NEXT_NO_ACTIVATE=1`) never writes it: a test build
/// must not take over the user's `cmux`.
///
/// Builds before goals/next-store-out-of-classic wrote it in classic cmux's
/// `Application Support/cmux` (``legacyFile``); a publish removes that one,
/// so NEXT leaves nothing in classic's folder and no reader finds a stale app.
public struct LastAppCLIPointer: Sendable, Equatable {
    public let file: URL
    public let legacyFile: URL

    public init(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        file = userHome.appendingPathComponent("Library/Application Support/cmux-next/last-app-cli")
        legacyFile = userHome.appendingPathComponent("Library/Application Support/cmux/last-app-cli")
    }

    /// Whether a launch with `environment` is the user's own.
    public static func shouldPublish(environment: [String: String]) -> Bool {
        environment["CMUX_NEXT_NO_ACTIVATE"] != "1"
    }

    /// At launch: points the pointer at this app's CLI, off the main thread, unless the launch is an agent's.
    public static func publishAtLaunch(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) {
        guard shouldPublish(environment: environment), let cli = bundle.resourceURL?.appendingPathComponent("bin/cmux").path else { return }
        // task-owner: one small write at launch; it ends on its own and nothing waits on it
        Task.detached(priority: .utility) { LastAppCLIPointer().publish(cliPath: cli) }
    }

    /// Whether `path` is in a copy that is gone at the next restart or eject: App Translocation's randomized
    /// mirror (an app opened from Downloads without being moved) or a read-only volume (the disk image).
    public static func isPassing(_ path: String) -> Bool {
        if path.contains("/AppTranslocation/") { return true }
        var stats = statfs()
        return statfs(path, &stats) == 0 && stats.f_flags & UInt32(bitPattern: MNT_RDONLY) != 0
    }

    /// Points the pointer at `cliPath`. False, and nothing written, when the
    /// path is not absolute, not an executable file, or in a passing copy
    /// (``isPassing(_:)``): a pointer there runs nothing after a restart.
    @discardableResult
    public func publish(cliPath: String) -> Bool {
        guard cliPath.hasPrefix("/"), !Self.isPassing(cliPath), FileManager.default.isExecutableFile(atPath: cliPath) else { return false }
        let directory = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let temporary = directory.appendingPathComponent(".last-app-cli.\(getpid()).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        let bytes = Array((cliPath + "\n").utf8)
        let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        guard written == bytes.count, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        unlink(legacyFile.path)
        return true
    }
}
