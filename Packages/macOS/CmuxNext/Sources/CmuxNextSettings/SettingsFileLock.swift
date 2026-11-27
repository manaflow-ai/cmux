import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// Another writer kept the lock of `cmux-next.json` for ``SettingsFileLock/patience``, so this
/// write did not finish. A write of one edit wrote nothing. A write of several steps (a reset
/// of a key and its old names, a shortcut reset) can have written its first steps. The same
/// write sent again completes it.
public nonisolated struct SettingsFileBusy: Error, Sendable, CustomStringConvertible, Equatable {
    public var description: String {
        "another cmux process holds the lock of cmux-next.json; the write did not finish, send it again"
    }
}

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
/// the write (``SettingsFileBusy``), so a writer that stopped while it held the lock never holds
/// an app write forever. The wait is never on the caller's thread: a lock another writer holds
/// is waited for on a queue of its own while the caller is suspended.
///
/// The app's writes get the lock in call order. While one write waits, each later write goes
/// behind it on the same queue and never tries the lock first, so a later value is never
/// published before an earlier one (a slider's burst of writes keeps its last value).
nonisolated struct SettingsFileLock: Sendable {
    /// -1: no lock is held (the lock file did not open or lock).
    private let descriptor: Int32

    /// How long a write waits for another writer. A writer holds the lock for one read, edit and
    /// publish of a small file (milliseconds).
    static let patience: Duration = .seconds(5)

    /// The one thread that waits in `flock`, one wait at a time in call order; a person may be
    /// waiting for the write.
    private static let waits = DispatchQueue(label: "com.cmuxterm.next.settings.file-lock", qos: .userInitiated)

    /// How many waits are on ``waits``, queued or in `flock`. While it is not 0 no write tries the
    /// lock directly.
    private static let waiting = Mutex(0)

    /// Takes the lock of the settings file at `url`. A free lock is taken at once when no earlier
    /// write waits; otherwise the write waits its turn off the caller's thread, for at most
    /// `patience`.
    ///
    /// It runs on its caller's actor up to the wait (this package's nonisolated async functions
    /// do), so the writes of one ``CmuxConfigFile`` take their places in the order of its calls.
    ///
    /// - Throws: ``SettingsFileBusy`` when the write did not get the lock within `patience`.
    static func acquire(file url: URL, patience: Duration = SettingsFileLock.patience) async throws -> SettingsFileLock {
        let directory = url.deletingLastPathComponent()
        try? FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: ".\(url.lastPathComponent).lock").path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { return SettingsFileLock(descriptor: -1) }
        return try await withCheckedThrowingContinuation { continuation in
            // One decision per write, in call order: the try and the place on the queue are one
            // step, so a write never passes one that came before it.
            let taken = waiting.withLock { count -> SettingsFileLock? in
                if count == 0 {
                    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return SettingsFileLock(descriptor: descriptor) }
                    if errno != EWOULDBLOCK {
                        close(descriptor)
                        return SettingsFileLock(descriptor: -1)
                    }
                }
                count += 1
                let wait = Wait(descriptor: descriptor, continuation: continuation)
                let deadline = DemandTimer(owner: "settings.file-lock")
                deadline.schedule(after: patience) { wait.giveUp() }
                waits.async {
                    wait.lock()
                    deadline.cancel()
                    waiting.withLock { $0 -= 1 }
                }
                return nil
            }
            if let taken { continuation.resume(returning: taken) }
        }
    }

    /// Releases the lock.
    func release() {
        if descriptor >= 0 { close(descriptor) }
    }

    /// One wait for the lock: the caller hears once, the lock or ``SettingsFileBusy``, whichever
    /// is first. Exactly one side closes the descriptor of a wait that gets no lock: the deadline
    /// when the wait has not reached `flock` yet, the queue when it has (a close there drops a
    /// lock the kernel granted meanwhile).
    private final class Wait: Sendable {
        private nonisolated enum Phase {
            case queued, locking, over
        }

        private nonisolated struct State {
            var phase = Phase.queued
            var waiter: CheckedContinuation<SettingsFileLock, any Error>?
        }

        private let descriptor: Int32
        private let state: Mutex<State>

        init(descriptor: Int32, continuation: CheckedContinuation<SettingsFileLock, any Error>) {
            self.descriptor = descriptor
            state = Mutex(State(waiter: continuation))
        }

        /// The deadline: the caller hears ``SettingsFileBusy`` unless it already has the lock.
        func giveUp() {
            let (waiter, unstarted) = state.withLock { state -> (CheckedContinuation<SettingsFileLock, any Error>?, Bool) in
                defer { state.waiter = nil }
                guard state.phase == .queued else { return (state.waiter, false) }
                state.phase = .over
                return (state.waiter, true)
            }
            if unstarted { close(descriptor) }
            waiter?.resume(throwing: SettingsFileBusy())
        }

        /// On the waits queue: blocks in `flock` until the other writer lets go.
        func lock() {
            let started = state.withLock { state -> Bool in
                guard state.phase == .queued else { return false }
                state.phase = .locking
                return true
            }
            guard started else { return }
            var result = flock(descriptor, LOCK_EX)
            while result != 0, errno == EINTR { result = flock(descriptor, LOCK_EX) }
            let waiter = state.withLock { state -> CheckedContinuation<SettingsFileLock, any Error>? in
                defer { state.waiter = nil }
                state.phase = .over
                return state.waiter
            }
            guard let waiter else {
                close(descriptor)
                return
            }
            if result == 0 {
                waiter.resume(returning: SettingsFileLock(descriptor: descriptor))
            } else {
                close(descriptor)
                waiter.resume(returning: SettingsFileLock(descriptor: -1))
            }
        }
    }
}
