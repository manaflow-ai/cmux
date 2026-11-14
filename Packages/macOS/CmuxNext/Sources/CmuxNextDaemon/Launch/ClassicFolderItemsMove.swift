import Darwin
import CmuxNextCompat
public import Foundation
import os

/// One-time moves of the items NEXT kept loose in classic cmux's
/// `~/Library/Application Support/cmux` to the same names under `cmux-next`
/// (cmuxterm-hq goals/next-store-out-of-classic.md), beside ``StateFolderMove``,
/// which runs it at launch before anything reads them.
///
/// Only items worth keeping move: the server fix ledger and unsaved recovery
/// drafts (folders, renamed once with a symlink left for an older build, as
/// ``StateFolderMove`` does) and a kept-name build's Debug Settings file
/// (``moveDebugTunables(to:tag:bundleID:)``, when Debug Settings starts).
/// Caches and regenerated files just start in the new place.
public struct ClassicFolderItemsMove: Sendable {
    /// Folders only NEXT writes in classic's `cmux`.
    static let folders = ["server-fix-ledger", "recovery"]

    let applicationSupport: URL
    private static let logger = Logger(subsystem: "com.cmuxterm.next", category: "daemon")

    public init(applicationSupport: URL = DaemonLauncher.applicationSupportDirectory()) {
        self.applicationSupport = applicationSupport
    }

    /// Moves each of ``folders``, once. Cheap when there is nothing to move: one `lstat` each.
    @discardableResult
    public func run() -> [StateFolderMove.Outcome] {
        Self.folders.map { name in
            let (old, new) = paths(name)
            var info = stat()
            guard lstat(old.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return .nothing }
            return log(StateFolderMove.move(old: old, new: new), old: old)
        }
    }

    /// Moves the file at `relativePath` below classic's `cmux` to the same path below `cmux-next`,
    /// once: only a regular file moves, and never over anything already at the new path.
    @discardableResult
    public func moveFile(_ relativePath: String) -> StateFolderMove.Outcome {
        let (old, new) = paths(relativePath)
        var info = stat()
        guard lstat(old.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .nothing }
        do {
            try FileManager.checked.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return log(.kept("cannot make \(new.deletingLastPathComponent().path): \(error.localizedDescription)"), old: old)
        }
        // RENAME_EXCL: refuses (EEXIST) when a file is already at `new`.
        guard renamex_np(old.path, new.path, UInt32(bitPattern: RENAME_EXCL)) == 0 else {
            return log(.kept("rename: \(String(cString: strerror(errno)))"), old: old)
        }
        return log(.moved, old: old)
    }

    /// A build that keeps its app names keeps its Debug Settings file here, relative to `cmux-next`
    /// (and to classic's `cmux` before): `<tag or channel>/debug-tunables.json`.
    public static func debugTunables(tag: String?, bundleID: String?) -> String {
        let folder = tag ?? (bundleID.map { $0.hasPrefix(BuildIdentity.nightlyBundleID) ? "nightly" : "dev" } ?? "dev")
        return "\(folder)/debug-tunables.json"
    }

    /// Moves a kept-name build's Debug Settings file (``debugTunables(tag:bundleID:)``) once,
    /// when `url` (the file the build reads) is its place under `cmux-next`; nothing for an override or a per-key build.
    @discardableResult
    public func moveDebugTunables(to url: URL, tag: String?, bundleID: String?) -> StateFolderMove.Outcome {
        let file = Self.debugTunables(tag: tag, bundleID: bundleID)
        return url.path.hasSuffix("/cmux-next/\(file)") ? moveFile(file) : .nothing
    }

    private func paths(_ relativePath: String) -> (old: URL, new: URL) {
        (applicationSupport.appending(path: "cmux/\(relativePath)"),
         DaemonLauncher.nextSupport(applicationSupport).appending(path: relativePath))
    }

    private func log(_ outcome: StateFolderMove.Outcome, old: URL) -> StateFolderMove.Outcome {
        if case .kept(let why) = outcome {
            Self.logger.error("\(old.path, privacy: .public) stays in classic's folder: \(why, privacy: .public)")
        } else {
            Self.logger.notice("\(old.path, privacy: .public) moved to cmux-next")
        }
        return outcome
    }
}
