import Darwin
import Foundation
import os

nonisolated extension AcpmuxServerPeer {
    /// What the strict team check (``executableSignedByAppTeam(_:team:)``) found for each file, kept
    /// for the file as it is on disk. The check hashes every page of the file, which took 1.7-2.1 s on a
    /// loaded Mac, and `AcpmuxEnvironment.resolve` asks it from synchronous callers on the main thread
    /// (nightly hang reports, 2026-11-05). Asked again about a file that has not changed, it answers
    /// from here and reads nothing.
    ///
    /// A file has not changed while its device, inode, size, modification time and status-change
    /// time are the same. A write to a file moves its status-change time, which only root can set
    /// back, and a file renamed over it has another inode, so a binary patched with `write` or
    /// replaced after it was checked is checked again in full. Two limits: a write through a shared
    /// mapping may move those times only when its pages are flushed (a patched code page of a signed
    /// binary still fails the kernel's page-in check), and a volume with coarse timestamps can hide a
    /// second write in the same second, so a file changed within ``settleSeconds`` of the check is
    /// never kept ("racy git"). Only passing verdicts are kept, so a refusal is asked again, and only in
    /// memory: a verdict on disk could be written by the same user it guards against.
    final class StrictVerdicts: Sendable {
        static let shared = StrictVerdicts()

        /// How long after its last change a file's verdict is not kept: longer than the coarsest
        /// timestamp a Mac volume keeps (one second on HFS+, two on FAT).
        static let settleSeconds: Int64 = 3

        /// The identity each (team, path) had when it passed.
        private let kept = OSAllocatedUnfairLock(initialState: [String: FileIdentity]())
        /// Seconds since 1970, the clock file times are in.
        private let now: @Sendable () -> Int64

        init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
            self.now = now
        }

        /// `validate`'s answer for the file at `path` (symlinks already resolved) under `team`, from
        /// the kept verdict while the file is unchanged. A file that cannot be stat'd, changed while
        /// `validate` read it or within ``settleSeconds`` before, or that failed, is checked every time.
        func verdict(path: String, team: String, validate: () -> Bool) -> Bool {
            let key = team + "\u{0}" + path
            guard let before = FileIdentity(path: path) else { return validate() }
            if kept.withLock({ $0[key] }) == before { return true }
            let valid = validate()
            if valid, FileIdentity(path: path) == before,
               max(before.modified, before.changed) + Self.settleSeconds <= now() {
                kept.withLock { $0[key] = before }
            } else {
                kept.withLock { _ = $0.removeValue(forKey: key) }
            }
            return valid
        }
    }

    /// A file's identity on disk, from `stat`.
    struct FileIdentity: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modified: Int64
        let modifiedNanoseconds: Int64
        let changed: Int64
        let changedNanoseconds: Int64

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modified = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changed = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }
}
