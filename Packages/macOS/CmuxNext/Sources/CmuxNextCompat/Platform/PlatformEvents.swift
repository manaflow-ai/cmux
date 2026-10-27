#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import CCmuxNextLinux
import Glibc
#else
#error("PlatformEvents needs kqueue (Darwin) or epoll (Linux)")
#endif

/// One dedicated thread's only wait: a kernel queue holding a one-shot timer and a user event, so a
/// thread that sleeps until "this deadline or that wake" costs no wakeup until one of them happens
/// (plans/cmux-next/idle-wakeups.md). Chromium's message pumps wait the same way:
/// base/message_loop/message_pump_kqueue.cc (an `EVFILT_USER` wakeup and an `EVFILT_TIMER` for the next
/// delayed task) and base/message_loop/message_pump_epoll.cc (an eventfd wakeup in one epoll set).
///
/// - Darwin: one kqueue with an `EVFILT_TIMER` (`NOTE_NSECONDS`, one-shot) and an `EVFILT_USER`.
/// - Linux: one epoll set with a `CLOCK_MONOTONIC` timerfd and an eventfd.
///
/// ``arm(afterNanos:)``, ``disarm()`` and ``wake()`` are one system call each and never block, so any
/// thread may call them, the main thread included; the kernel holds the deadline and no thread runs for
/// it. ``wait(nanos:)`` blocks its caller: only the one thread that owns the instance calls it.
///
/// ```swift
/// let events = PlatformEvents()
/// events.arm(afterNanos: 250_000_000)       // the main thread, as its turn starts
/// let fired = events.wait(nanos: nil)        // the watchdog thread: returns on the timer or a wake()
/// ```
public final class PlatformEvents: Sendable {
    /// What ended a ``PlatformEvents/wait(nanos:)``; empty when its timeout passed or a signal ended it.
    public struct Fired: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// The armed timer expired.
        public static let timer = Fired(rawValue: 1 << 0)
        /// ``PlatformEvents/wake()`` ran.
        public static let user = Fired(rawValue: 1 << 1)
    }

    /// The kqueue or epoll set; -1 when the kernel refused one (``isAvailable``).
    private let descriptor: Int32
    #if os(Linux)
    /// The timerfd and the eventfd in the epoll set (-1 with it).
    private let timerDescriptor: Int32
    private let userDescriptor: Int32
    #endif

    // The kevent and epoll constants are small Int32 flags and filters, and `nanos % 1e9` is under 1e9, so
    // every conversion here fits; `truncatingIfNeeded:` says so without a trap path.
    private static let timerIdent: UInt = 1
    private static let userIdent: UInt = 2

    #if canImport(Darwin)
    public init() {
        descriptor = kqueue()
        guard descriptor >= 0 else { return }
        submit(ident: Self.userIdent, filter: EVFILT_USER, flags: EV_ADD | EV_CLEAR)
    }
    #elseif os(Linux)
    public init() {
        let queue = epoll_create1(Int32(EPOLL_CLOEXEC))
        let timer = timerfd_create(CLOCK_MONOTONIC, Int32(TFD_CLOEXEC | TFD_NONBLOCK))
        let user = eventfd(0, Int32(EFD_CLOEXEC | EFD_NONBLOCK))
        guard queue >= 0, timer >= 0, user >= 0,
              Self.add(timer, ident: Self.timerIdent, to: queue), Self.add(user, ident: Self.userIdent, to: queue) else {
            for descriptor in [queue, timer, user] where descriptor >= 0 { close(descriptor) }
            (descriptor, timerDescriptor, userDescriptor) = (-1, -1, -1)
            return
        }
        (descriptor, timerDescriptor, userDescriptor) = (queue, timer, user)
    }
    #endif

    deinit {
        guard descriptor >= 0 else { return }
        close(descriptor)
        #if os(Linux)
        close(timerDescriptor)
        close(userDescriptor)
        #endif
    }

    /// False when the kernel refused the queue; then every call does nothing and ``wait(nanos:)`` returns at once.
    public var isAvailable: Bool { descriptor >= 0 }

    /// Fires once, `nanos` from now (at least 1 ns), unless ``disarm()`` comes first. Arming again replaces the
    /// pending deadline.
    public func arm(afterNanos nanos: UInt64) {
        guard descriptor >= 0 else { return }
        #if canImport(Darwin)
        submit(ident: Self.timerIdent, filter: EVFILT_TIMER, flags: EV_ADD | EV_ONESHOT,
               fflags: UInt32(truncatingIfNeeded: NOTE_NSECONDS), data: Int(clamping: max(nanos, 1)))
        #elseif os(Linux)
        // A zero it_value disarms a timerfd, so the shortest deadline is 1 ns.
        setTimer(Self.interval(nanos: max(nanos, 1)))
        #endif
    }

    /// Drops a pending timer and one that fired but no wait has seen yet. None is fine.
    public func disarm() {
        guard descriptor >= 0 else { return }
        #if canImport(Darwin)
        submit(ident: Self.timerIdent, filter: EVFILT_TIMER, flags: EV_DELETE)
        #elseif os(Linux)
        // timerfd_settime resets the expiration count, so a fired, unread expiry goes with the deadline.
        setTimer(Self.interval(nanos: 0))
        #endif
    }

    /// Ends a wait now, or the next one if none runs. Several wakes before one wait end that one wait.
    public func wake() {
        guard descriptor >= 0 else { return }
        #if canImport(Darwin)
        submit(ident: Self.userIdent, filter: EVFILT_USER, flags: 0, fflags: UInt32(truncatingIfNeeded: NOTE_TRIGGER))
        #elseif os(Linux)
        var one: UInt64 = 1
        // SAFETY: write reads 8 bytes, the size given, from `one`, a local live for the call. A full counter
        // (EAGAIN) still leaves the eventfd readable, so the wake is not lost.
        _ = unsafe write(userDescriptor, &one, MemoryLayout<UInt64>.size)
        #endif
    }

    /// Blocks the calling thread (its owner, never the main thread) until the timer fires, ``wake()`` runs or
    /// `nanos` pass; nil waits with no limit. A signal may end it early (an empty result).
    ///
    /// - Returns: What fired; both when both did, empty on the timeout.
    @discardableResult
    public func wait(nanos: UInt64?) -> Fired {
        guard descriptor >= 0 else { return [] }
        #if canImport(Darwin)
        // SAFETY: zeroed events with a nil udata, which nothing here reads.
        var events = unsafe [Darwin.kevent](repeating: Darwin.kevent(), count: 2)
        let count: Int32
        if let nanos {
            var timeout = Self.interval(nanos: nanos)
            // concurrency-allow: the owning thread's bounded kevent wait; never the main thread.
            // SAFETY: kevent writes at most 2 events, the count given, into `events` and reads `timeout`, both
            // locals live for the call.
            count = unsafe kevent(descriptor, nil, 0, &events, 2, &timeout)
        } else {
            // concurrency-allow: the owning thread parks until the timer or a wake; never the main thread.
            // SAFETY: kevent writes at most 2 events, the count given, into `events`, a local live for the call.
            count = unsafe kevent(descriptor, nil, 0, &events, 2, nil)
        }
        var fired: Fired = []
        for index in 0..<Int(max(count, 0)) {
            // SAFETY: index < count <= 2, an event kevent wrote; only its ident is read.
            fired.insert(unsafe events[index].ident == Self.timerIdent ? .timer : .user)
        }
        return fired
        #elseif os(Linux)
        // SAFETY: zeroed events; only the u64 tag of the data union is ever read.
        var events = unsafe [epoll_event](repeating: epoll_event(), count: 2)
        // epoll_wait takes milliseconds: round up, so the wait never ends before `nanos` (Chromium's pump
        // rounds its delayed-work timeout up the same way). -1 waits with no limit.
        let timeout = nanos.map { Int32(clamping: $0 / 1_000_000 + ($0 % 1_000_000 == 0 ? 0 : 1)) } ?? -1
        // concurrency-allow: the owning thread's epoll wait (bounded when `nanos` is given); never the main thread.
        // SAFETY: epoll_wait writes at most 2 events, the count given, into `events`, a local live for the call.
        let count = unsafe epoll_wait(descriptor, &events, 2, timeout)
        var fired: Fired = []
        for index in 0..<Int(max(count, 0)) {
            // SAFETY: index < count <= 2, an event epoll_wait wrote; its tag is the u64 that add(_:ident:to:) set.
            let ident = unsafe UInt(truncatingIfNeeded: events[index].data.u64)
            fired.insert(ident == Self.timerIdent ? .timer : .user)
            drain(ident == Self.timerIdent ? timerDescriptor : userDescriptor)
        }
        return fired
        #endif
    }

    private static func interval(nanos: UInt64) -> timespec {
        timespec(tv_sec: Int(clamping: nanos / 1_000_000_000), tv_nsec: Int(truncatingIfNeeded: nanos % 1_000_000_000))
    }

    #if canImport(Darwin)
    /// Registers one change with the kqueue, with no event list back.
    private func submit(ident: UInt, filter: Int32, flags: Int32, fflags: UInt32 = 0, data: Int = 0) {
        // SAFETY: udata is nil (no context pointer), and the change is a local live for the kevent call, which
        // reads that one change and, with a nil event list of count 0, writes nothing back.
        var change = unsafe kevent(ident: ident, filter: Int16(truncatingIfNeeded: filter), flags: UInt16(truncatingIfNeeded: flags),
                                   fflags: fflags, data: data, udata: nil)
        // SAFETY: as above.
        _ = unsafe kevent(descriptor, &change, 1, nil, 0, nil)
    }
    #elseif os(Linux)
    /// Adds `fd` to the epoll set `queue`, readable events tagged with `ident`.
    private static func add(_ fd: Int32, ident: UInt, to queue: Int32) -> Bool {
        // SAFETY: the data union holds the u64 tag only; its pointer member is never set or read.
        var event = unsafe epoll_event(events: EPOLLIN.rawValue, data: epoll_data_t(u64: UInt64(ident)))
        // SAFETY: epoll_ctl reads one epoll_event from `event`, a local live for the call.
        return unsafe epoll_ctl(queue, EPOLL_CTL_ADD, fd, &event) == 0
    }

    /// Sets the timerfd's one-shot deadline relative to now; a zero `value` disarms it.
    private func setTimer(_ value: timespec) {
        var spec = itimerspec(it_interval: Self.interval(nanos: 0), it_value: value)
        // SAFETY: timerfd_settime reads one itimerspec from `spec`, a local live for the call; the old value is
        // not asked for (nil).
        _ = unsafe timerfd_settime(timerDescriptor, 0, &spec, nil)
    }

    /// Reads a timerfd's expiry count or an eventfd's counter, so the next wait sleeps again (non-blocking).
    private func drain(_ fd: Int32) {
        var count: UInt64 = 0
        // SAFETY: read writes at most 8 bytes, the size given, into `count`, a local live for the call.
        _ = unsafe read(fd, &count, MemoryLayout<UInt64>.size)
    }
    #endif
}
