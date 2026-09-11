public import Foundation
internal import Darwin

/// Waits for a startup-racing control socket with vnode events and bounded retries.
///
/// The waiter owns the common deadline, path re-resolution, vnode observation,
/// and bounded retry policy used by command-line clients that launch or race
/// the cmux app. The caller retains ownership of the concrete connection and
/// decides which connection failures are transient:
///
/// ```swift
/// let client = try SocketStartupWaiter().wait(
///     timeout: 45,
///     resolvePath: resolveCurrentSocketPath
/// ) { path, remainingTime in
///     try connectIfAvailable(path, timeout: remainingTime)
/// }
/// ```
public struct SocketStartupWaiter {
    private let initialRetryDelay: TimeInterval
    private let maximumRetryDelay: TimeInterval
    private let monotonicTime: () -> TimeInterval
    private let eventQueueFactory: () -> Int32
    private let vnodeEventWaiter: (_ queue: Int32, _ timeout: TimeInterval) -> Bool
    private let retryDelayWaiter: (_ timeout: TimeInterval) -> Void

    /// Creates a startup waiter with bounded exponential retry delays.
    ///
    /// - Parameters:
    ///   - initialRetryDelay: Delay after the first unavailable attempt. Values
    ///     below one millisecond are clamped to one millisecond.
    ///   - maximumRetryDelay: Maximum delay between attempts. Values below the
    ///     normalized initial delay are raised to that delay.
    ///   - monotonicTime: Monotonic seconds used for deadlines. Tests may inject
    ///     a controlled clock; production defaults to system uptime.
    public init(
        initialRetryDelay: TimeInterval = 0.025,
        maximumRetryDelay: TimeInterval = 0.5,
        monotonicTime: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.init(
            initialRetryDelay: initialRetryDelay,
            maximumRetryDelay: maximumRetryDelay,
            monotonicTime: monotonicTime,
            eventQueueFactory: { kqueue() },
            vnodeEventWaiter: nil,
            retryDelayWaiter: nil
        )
    }

    init(
        initialRetryDelay: TimeInterval,
        maximumRetryDelay: TimeInterval,
        monotonicTime: @escaping () -> TimeInterval,
        eventQueueFactory: @escaping () -> Int32,
        vnodeEventWaiter: ((_ queue: Int32, _ timeout: TimeInterval) -> Bool)? = nil,
        retryDelayWaiter: ((_ timeout: TimeInterval) -> Void)? = nil
    ) {
        let finiteInitialDelay = initialRetryDelay.isFinite ? initialRetryDelay : 0.025
        let normalizedInitialDelay = max(finiteInitialDelay, 0.001)
        let finiteMaximumDelay = maximumRetryDelay.isFinite ? maximumRetryDelay : 0.5
        self.initialRetryDelay = normalizedInitialDelay
        self.maximumRetryDelay = max(finiteMaximumDelay, normalizedInitialDelay)
        self.monotonicTime = monotonicTime
        self.eventQueueFactory = eventQueueFactory
        self.vnodeEventWaiter = vnodeEventWaiter ?? { queue, timeout in
            SocketStartupWaiter.waitForVnodeEvent(
                queue,
                timeout: timeout,
                monotonicTime: monotonicTime
            )
        }
        self.retryDelayWaiter = retryDelayWaiter ?? { timeout in
            SocketStartupWaiter.waitForRetryDelay(
                timeout,
                monotonicTime: monotonicTime
            )
        }
    }

    /// Waits until `attemptConnection` produces a connection or the deadline expires.
    ///
    /// `resolvePath` runs before every attempt so a fallback selected during app
    /// startup can replace an earlier preferred path. Returning `nil` from
    /// `attemptConnection` classifies that attempt as transient; throwing fails
    /// immediately. Directory vnode events wake the waiter when possible, while
    /// the bounded timeout also covers a listener beginning to accept on an
    /// unchanged socket inode.
    ///
    /// - Parameters:
    ///   - timeout: Total wait budget in seconds. A non-finite or negative value
    ///     becomes zero; one immediate connection attempt is still made.
    ///   - resolvePath: Supplies the currently authoritative socket path.
    ///   - attemptConnection: Attempts one connection. It receives the selected
    ///     path and remaining total budget, returns a connection on success,
    ///     returns `nil` for a transient failure, or throws a permanent failure.
    /// - Returns: The first connection produced by `attemptConnection`.
    /// - Throws: ``SocketStartupWaitTimeout`` when the budget expires, or a
    ///   permanent error from `attemptConnection`.
    public func wait<Connection>(
        timeout: TimeInterval,
        resolvePath: () -> String,
        attemptConnection: (_ path: String, _ remainingTime: TimeInterval) throws -> Connection?
    ) throws -> Connection {
        let normalizedTimeout = timeout.isFinite ? max(timeout, 0) : 0
        let deadline = monotonicTime() + normalizedTimeout
        let eventQueue = eventQueueFactory()
        var lastPath = resolvePath()
        defer {
            if eventQueue >= 0 {
                Darwin.close(eventQueue)
            }
        }

        var watchedDirectoryFD: Int32 = -1
        var watchedDirectoryPath: String?
        defer {
            if watchedDirectoryFD >= 0 {
                Darwin.close(watchedDirectoryFD)
            }
        }

        var retryDelay = initialRetryDelay
        while true {
            let currentPath = resolvePath()
            lastPath = currentPath
            let remainingBeforeAttempt = max(deadline - monotonicTime(), 0)
            if let connection = try attemptConnection(currentPath, remainingBeforeAttempt) {
                return connection
            }

            let remaining = deadline - monotonicTime()
            guard remaining > 0 else {
                throw SocketStartupWaitTimeout(path: lastPath)
            }

            if eventQueue >= 0,
               let directory = existingWatchDirectory(forPath: currentPath),
               directory != watchedDirectoryPath {
                if watchedDirectoryFD >= 0 {
                    Darwin.close(watchedDirectoryFD)
                    watchedDirectoryFD = -1
                }
                watchedDirectoryFD = registerSocketDirectory(directory, queue: eventQueue) ?? -1
                watchedDirectoryPath = watchedDirectoryFD >= 0 ? directory : nil
            }

            let retryTimeout = min(retryDelay, remaining)
            // Vnode activity may accelerate a retry, but never by more than 2x
            // once exponential backoff grows. This coalesces unrelated parent-
            // directory churn instead of resolving and probing once per event.
            let minimumEventDelay = min(
                max(initialRetryDelay, retryDelay / 2),
                retryTimeout
            )
            waitForRetryOpportunity(
                eventQueue,
                timeout: retryTimeout,
                minimumEventDelay: minimumEventDelay
            )
            retryDelay = min(retryDelay * 2, maximumRetryDelay)
        }
    }

    private func existingWatchDirectory(forPath path: String) -> String? {
        var candidate = (path as NSString).deletingLastPathComponent
        while !candidate.isEmpty {
            var fileStatus = stat()
            if lstat(candidate, &fileStatus) == 0,
               (fileStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                return candidate
            }
            guard candidate != "/" else { break }
            let parent = (candidate as NSString).deletingLastPathComponent
            guard parent != candidate else { break }
            candidate = parent
        }
        return nil
    }

    private func registerSocketDirectory(_ path: String, queue: Int32) -> Int32? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        var event = kevent(
            ident: UInt(descriptor),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: UInt32(NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_EXTEND | NOTE_LINK),
            data: 0,
            udata: nil
        )
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    private func waitForRetryOpportunity(
        _ queue: Int32,
        timeout: TimeInterval,
        minimumEventDelay: TimeInterval
    ) {
        guard timeout > 0 else { return }
        guard queue >= 0 else {
            retryDelayWaiter(timeout)
            return
        }
        let startedAt = monotonicTime()
        let timeoutDeadline = startedAt + timeout
        let normalizedMinimumEventDelay = min(max(minimumEventDelay, 0), timeout)
        let earliestEventRetry = startedAt + normalizedMinimumEventDelay
        // Once the minimum retry cadence has elapsed, there is no benefit in
        // continuing to wait for an event: the bounded retry itself covers an
        // unchanged inode beginning to listen.
        let observedEvent = vnodeEventWaiter(queue, normalizedMinimumEventDelay)
        let deadline = observedEvent ? earliestEventRetry : timeoutDeadline
        let unsleptRemainder = deadline - monotonicTime()
        if unsleptRemainder > 0 {
            retryDelayWaiter(unsleptRemainder)
        }
    }

    private static func waitForVnodeEvent(
        _ queue: Int32,
        timeout: TimeInterval,
        monotonicTime: () -> TimeInterval
    ) -> Bool {
        let deadline = monotonicTime() + timeout
        while true {
            let remaining = deadline - monotonicTime()
            guard remaining > 0 else { return false }
            var timeoutSpec = timespec(
                tv_sec: Int(remaining),
                tv_nsec: Int((remaining - floor(remaining)) * 1_000_000_000)
            )
            var triggeredEvent = kevent()
            let result = kevent(queue, nil, 0, &triggeredEvent, 1, &timeoutSpec)
            if result > 0 {
                return true
            }
            if result == 0 || errno != EINTR {
                return false
            }
        }
    }

    private static func waitForRetryDelay(
        _ timeout: TimeInterval,
        monotonicTime: () -> TimeInterval
    ) {
        let deadline = monotonicTime() + timeout
        while true {
            let remaining = deadline - monotonicTime()
            guard remaining > 0 else { return }
            var delay = timespec(
                tv_sec: Int(remaining),
                tv_nsec: Int((remaining - floor(remaining)) * 1_000_000_000)
            )
            if nanosleep(&delay, nil) == 0 || errno != EINTR {
                return
            }
        }
    }
}
