import Darwin
public import CmuxNextCompat
public import Foundation
import os

/// One-time move of a build's own folder out of classic cmux's
/// `~/Library/Application Support/cmux` (cmuxterm-hq goals/next-store-out-of-classic.md).
///
/// Builds before this kept their daemon state, sidebar snapshot and
/// legacy-session marker in `cmux/tags/<tag>/` (a channel or tagged build)
/// or `cmux/builds/<key>/`, inside classic's folder: deleting classic's
/// folder wiped NEXT's workspaces, and resetting NEXT left them behind
/// (experiments/setup-flows/airblue-2026-11-08.md issue 5). Each build now
/// keeps that folder under `cmux-next/` (``DaemonLauncher/nextSupport(_:)``).
///
/// At launch, before anything reads the folder, the build renames its own old
/// folder to the new place: one `rename(2)` within one volume, so nothing is
/// copied and nothing can diverge. A daemon an older app left running keeps
/// working through it: its open files survive the rename, the symlink left at
/// the old path resolves what it opens later, and terminal hosts are found
/// by session, not by path (the next daemon adopts them). The symlink also
/// lets a rolled-back build find its state. A real folder already at the new
/// place is never replaced: the old one stays, and the launch says so in the log.
public struct StateFolderMove: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// No old folder, or it is already the symlink a move left.
        case nothing
        case moved
        /// The old folder stays where it is; the reason is for the log.
        case kept(String)
    }

    let applicationSupport: URL
    private static let logger = Logger(subsystem: "com.cmuxterm.next", category: "daemon")

    public init(applicationSupport: URL = DaemonLauncher.applicationSupportDirectory()) {
        self.applicationSupport = applicationSupport
    }

    /// The build's folder in classic's `cmux` and under `cmux-next`: the parent of its daemon state
    /// directory in each. Nil for a build with cmux-tui's default root (release, outside any bundle).
    public func folders(build: BuildIdentity) -> (old: URL, new: URL)? {
        let classic = applicationSupport.appendingPathComponent("cmux", isDirectory: true)
        guard let old = build.daemonStateDirectory(appSupport: classic)?.deletingLastPathComponent(),
              let new = build.daemonStateDirectory(appSupport: DaemonLauncher.nextSupport(applicationSupport))?
                .deletingLastPathComponent() else { return nil }
        return (old, new)
    }

    /// Moves `build`'s old folder, once. Cheap when there is nothing to move: one `lstat`.
    @discardableResult
    public func run(build: BuildIdentity) -> Outcome {
        guard let pair = folders(build: build) else { return .nothing }
        let (old, new) = pair
        var info = stat()
        guard lstat(old.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return .nothing }
        let outcome = move(old: old, new: new)
        if case .kept(let why) = outcome {
            Self.logger.error("state folder \(old.path, privacy: .public) stays: \(why, privacy: .public)")
        } else {
            Self.logger.notice("state folder moved to \(new.path, privacy: .public)")
        }
        return outcome
    }

    private func move(old: URL, new: URL) -> Outcome {
        do {
            try FileManager.checked.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return .kept("cannot make \(new.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        // rename(2) replaces an empty folder at `new` and refuses one with files (ENOTEMPTY, EEXIST).
        guard rename(old.path, new.path) == 0 else {
            return .kept("rename: \(String(cString: strerror(errno)))")
        }
        // Best effort: without the link a running older daemon still has its open files, and the next one starts here.
        _ = symlink(new.path, old.path)
        return .moved
    }
}
