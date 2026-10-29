import CmuxNextCompat
import Darwin
public import Foundation

/// The "last opened app" pointer: the absolute path of the `cmux` CLI of the
/// app the user opened last, in `~/Library/Application Support/cmux/last-app-cli`.
///
/// A `cmux` shim outside the app's terminals (the `reload.sh` dev shim) reads
/// it to run the CLI that matches the app, not an older installed one
/// (plans/cmux-next/version-skew.md). The app is its only writer, once at
/// launch: written to a temporary file in the same directory (mode 0600)
/// and renamed over the old pointer, so a reader never sees a partial path,
/// and a symlink put in its place is replaced, never followed. An isolated
/// launch (``LaunchIsolation/isolated``: an agent or bench launch) never
/// writes it: a test build must not take over the user's `cmux`.
public struct LastAppCLIPointer: Sendable, Equatable {
    public let file: URL

    public init(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        file = userHome.appendingPathComponent("Library/Application Support/cmux/last-app-cli")
    }

    /// Whether a launch with `environment` is the user's own.
    public static func shouldPublish(environment: [String: String]) -> Bool {
        !LaunchIsolation(environment: environment).isolated
    }

    /// Points the pointer at `cliPath`. False, and nothing written, when the
    /// path is not absolute or not an executable file.
    @discardableResult
    public func publish(cliPath: String) -> Bool {
        guard cliPath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: cliPath) else { return false }
        let directory = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let temporary = directory.appendingPathComponent(".last-app-cli.\(getpid()).\(UUID().uuidString)")
        // SAFETY: open reads the NUL-terminated copy of the path Swift makes for the call.
        let descriptor = unsafe blockingOpen(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let written = (try? handle.blockingWrite(contentsOf: Data((cliPath + "\n").utf8))) != nil
        close(descriptor)
        // SAFETY: rename and unlink read the NUL-terminated copies of the paths made for each call.
        guard written, unsafe blockingRename(temporary.path, file.path) == 0 else {
            _ = unsafe blockingUnlink(temporary.path)
            return false
        }
        return true
    }
}
