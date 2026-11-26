import Darwin
import Foundation

/// Wakes the Codex transcript monitor when its rollout or lease file changes.
///
/// The monitor reads the transcript and then blocks until the next change. A
/// watch created after the read misses a write that lands between the read and
/// the watch, and the monitor then sleeps until its 30 second backstop. This
/// watcher keeps one kqueue registration per file for its whole lifetime.
/// `arm(paths:)` registers synchronously, so a caller that arms before reading
/// sees every later write in the next `wait(timeout:)`: `EV_CLEAR` keeps the
/// event pending until it is delivered.
///
/// The type is not thread safe. One monitor loop owns it.
public final class CodexTranscriptChangeWatcher {
    /// How a `wait(timeout:)` call ended.
    public enum WaitResult: Equatable, Sendable {
        /// A watched file was written, extended, deleted or renamed.
        case changed
        /// The timeout elapsed with no change.
        case timedOut
    }

    private struct Registration {
        let descriptor: Int32
        let device: dev_t
        let inode: ino_t
    }

    private static let eventFlags = UInt32(NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME)

    private let queue: Int32
    private var registrations: [String: Registration] = [:]

    /// Creates a watcher with no registrations.
    public init() {
        queue = kqueue()
    }

    deinit {
        for registration in registrations.values {
            Darwin.close(registration.descriptor)
        }
        if queue >= 0 {
            Darwin.close(queue)
        }
    }

    /// Watches exactly `paths`, reusing registrations whose file is unchanged.
    ///
    /// A path whose file was replaced (a different device or inode) is
    /// registered again on the new file. A path that does not exist yet is
    /// skipped and retried on the next call. The registration is active when
    /// this returns.
    ///
    /// - Parameter paths: File paths to watch. A leading `~` is expanded.
    public func arm(paths: [String]) {
        let wanted = Set(paths.filter { !$0.isEmpty }.map { NSString(string: $0).expandingTildeInPath })
        for (path, registration) in registrations where !wanted.contains(path) {
            Darwin.close(registration.descriptor)
            registrations[path] = nil
        }
        guard queue >= 0 else { return }
        for path in wanted {
            var status = stat()
            guard stat(path, &status) == 0 else {
                if let stale = registrations.removeValue(forKey: path) {
                    Darwin.close(stale.descriptor)
                }
                continue
            }
            if let existing = registrations[path],
               existing.device == status.st_dev,
               existing.inode == status.st_ino {
                continue
            }
            if let stale = registrations.removeValue(forKey: path) {
                Darwin.close(stale.descriptor)
            }
            register(path: path)
        }
    }

    /// Blocks until a watched file changes or `timeout` elapses.
    ///
    /// Changes made after the last `arm(paths:)` and before this call are
    /// reported at once.
    ///
    /// - Parameter timeout: The longest wait, in seconds.
    /// - Returns: `.changed` when a watched file changed.
    @discardableResult
    public func wait(timeout: TimeInterval) -> WaitResult {
        guard timeout > 0 else { return .timedOut }
        guard queue >= 0 else {
            // Without a kqueue there is nothing to wake on; keep the caller's
            // bounded cadence instead of spinning.
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + timeout)
            return .timedOut
        }
        let deadline = Date().addingTimeInterval(timeout)
        var events = Array(repeating: kevent(), count: 4)
        while true {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            let seconds = remaining.rounded(.down)
            var interval = timespec(
                tv_sec: Int(seconds),
                tv_nsec: Int((remaining - seconds) * 1_000_000_000)
            )
            let count = kevent(queue, nil, 0, &events, Int32(events.count), &interval)
            if count > 0 {
                return .changed
            }
            if count == 0 {
                return .timedOut
            }
            guard errno == EINTR, deadline.timeIntervalSinceNow > 0 else {
                return .timedOut
            }
        }
    }

    private func register(path: String) {
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            Darwin.close(descriptor)
            return
        }
        var change = kevent(
            ident: UInt(descriptor),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_CLEAR),
            fflags: Self.eventFlags,
            data: 0,
            udata: nil
        )
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            Darwin.close(descriptor)
            return
        }
        registrations[path] = Registration(
            descriptor: descriptor,
            device: status.st_dev,
            inode: status.st_ino
        )
    }
}
