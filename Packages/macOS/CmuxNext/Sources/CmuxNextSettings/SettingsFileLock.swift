import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// The write lock of `cmux-next.json`: one writer at a time holds it across its read, edit and
/// publish of the file.
///
/// It is the lock the daemon's settings owner takes (cmux-tui `cmux-config`, `owner.rs`,
/// `lock_config`), taken the same way so the two interlock: an exclusive `flock` on
/// `.<file name>.lock` beside the configured file, opened write-only and created when missing.
/// Beside the path as configured, never beside a symlink's target, so a dotfiles repository gets
/// no lock file. The daemon owns the settings; ``CmuxConfigFile`` still writes the file for the
/// app until those writes are `settings.*` operations (plans/cmux-next/settings-react.md, slice
/// b), and holds this lock so that neither side replaces the file with a text that lacks the
/// other's edit.
///
/// No stale lock exists: the kernel drops the lock when the descriptor closes or the process
/// ends, and neither side ever deletes the lock file (a new file would be a second lock). When
/// the lock file cannot be opened (a read-only folder) or locked, the write goes ahead without
/// the lock, as in the daemon: the publish reports any error.
///
/// Where the daemon waits without a limit, the app waits at most ``patience`` and then refuses
/// the write (``Busy``), so a writer that stopped while it held the lock never holds an app
/// write forever. The wait is never on the caller's thread: a lock another writer holds is
/// waited for on a queue of its own while the caller is suspended.
nonisolated struct SettingsFileLock: Sendable {
    /// -1: no lock is held (the lock file did not open or lock).
    private let descriptor: Int32

    /// The lock stayed with another writer for ``SettingsFileLock/patience``; nothing was written.
    struct Busy: Error, Sendable, CustomStringConvertible {
        var description: String { "another cmux process is writing cmux-next.json; nothing was written, try again" }
    }

    /// How long a write waits for another writer. A writer holds the lock for one read, edit and
    /// publish of a small file (milliseconds).
    static let patience: Duration = .seconds(5)

    /// The one thread that waits in `flock`; a person may be waiting for the write.
    private static let waits = DispatchQueue(label: "com.cmuxterm.next.settings.file-lock", qos: .userInitiated)

    /// Takes the lock of the settings file at `url`. A free lock is taken at once; a held one is
    /// waited for off the caller's thread, for at most `patience`.
    ///
    /// - Throws: ``Busy`` when another writer still holds the lock after `patience`.
    static func acquire(file url: URL, patience: Duration = SettingsFileLock.patience) async throws -> SettingsFileLock {
        let directory = url.deletingLastPathComponent()
        try? FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: ".\(url.lastPathComponent).lock").path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { return SettingsFileLock(descriptor: -1) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return SettingsFileLock(descriptor: descriptor) }
        guard errno == EWOULDBLOCK else {
            close(descriptor)
            return SettingsFileLock(descriptor: -1)
        }
        let wait = Wait(descriptor: descriptor)
        let deadline = DemandTimer(owner: "settings.file-lock")
        return try await withCheckedThrowingContinuation { continuation in
            wait.begin(continuation)
            deadline.schedule(after: patience) { wait.giveUp() }
            waits.async {
                wait.lock()
                deadline.cancel()
            }
        }
    }

    /// Releases the lock.
    func release() {
        if descriptor >= 0 { close(descriptor) }
    }

    /// One wait for a held lock: the caller hears once, the lock or ``Busy``, whichever is first.
    /// A wait given up on closes its descriptor when its turn on the queue comes, which drops the
    /// lock if the kernel granted it meanwhile.
    private final class Wait: Sendable {
        private let descriptor: Int32
        private let waiter = Mutex<CheckedContinuation<SettingsFileLock, any Error>?>(nil)
        private let givenUp = Mutex(false)

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        func begin(_ continuation: CheckedContinuation<SettingsFileLock, any Error>) {
            waiter.withLock { $0 = continuation }
        }

        /// The deadline: the caller hears ``Busy`` unless it already has the lock.
        func giveUp() {
            givenUp.withLock { $0 = true }
            take()?.resume(throwing: Busy())
        }

        /// On the waits queue: blocks in `flock` until the other writer lets go.
        func lock() {
            guard !givenUp.withLock({ $0 }) else {
                close(descriptor)
                return
            }
            var result = flock(descriptor, LOCK_EX)
            while result != 0, errno == EINTR { result = flock(descriptor, LOCK_EX) }
            guard let continuation = take() else {
                close(descriptor)
                return
            }
            if result == 0 {
                continuation.resume(returning: SettingsFileLock(descriptor: descriptor))
            } else {
                close(descriptor)
                continuation.resume(returning: SettingsFileLock(descriptor: -1))
            }
        }

        private func take() -> CheckedContinuation<SettingsFileLock, any Error>? {
            waiter.withLock { waiter in
                defer { waiter = nil }
                return waiter
            }
        }
    }
}
