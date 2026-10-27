import Darwin

/// The watchdog thread's only wait (``MainThreadWatchdog``): a kqueue holding one one-shot
/// timer, which the main thread arms when its run loop wakes and deletes before it sleeps, and
/// one user event that `stop()`, a scheduled task's start and a hang-watch scope trigger. A scope
/// triggers it only when the hang monitor would see it more than one minimum deadline late: the
/// first open after the monitor parks, one trigger (`HangWatch` `requestScan`). The monitor's own
/// scans need no timer of their own: they bound the wait's timeout (`HangMonitor.service()`).
///
/// A main-thread turn shorter than the timer wakes no other thread: an idle app's occasional
/// wakes cost the watchdog nothing (plans/cmux-next/idle-wakeups.md). A turn that outlasts it
/// wakes the watchdog thread once, which then checks every threshold until the turn ends.
/// Before, the main thread signalled a semaphore on every wake and the watchdog then waited
/// with a timeout that expired after the turn: two watchdog wakeups per main wake.
///
/// Arming and deleting are one `kevent` call each on the main thread; the kernel holds the
/// deadline, so no thread runs for it.
final class MainThreadWatchdogAlarm: Sendable {
    /// The kqueue; -1 when none could be made (the watchdog thread then does not run).
    private let descriptor: Int32
    // The kevent constants are small Int32 flags and filters, and `nanos % 1e9` is under 1e9, so
    // every conversion here fits; `truncatingIfNeeded:` says so without a trap path.
    private static let timerIdent: UInt = 1
    private static let stopIdent: UInt = 2

    init() {
        descriptor = kqueue()
        guard descriptor >= 0 else { return }
        submit(ident: Self.stopIdent, filter: EVFILT_USER, flags: EV_ADD | EV_CLEAR)
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// False when the kqueue could not be made.
    var isAvailable: Bool { descriptor >= 0 }

    /// Fires once, `nanos` from now, unless ``disarm()`` comes first (the main run loop woke).
    func arm(afterNanos nanos: UInt64) {
        guard descriptor >= 0 else { return }
        submit(ident: Self.timerIdent, filter: EVFILT_TIMER, flags: EV_ADD | EV_ONESHOT,
               fflags: UInt32(truncatingIfNeeded: NOTE_NSECONDS), data: Int(clamping: nanos))
    }

    /// Drops a pending or fired timer (the main run loop is about to sleep). None is fine (ENOENT).
    func disarm() {
        guard descriptor >= 0 else { return }
        submit(ident: Self.timerIdent, filter: EVFILT_TIMER, flags: EV_DELETE)
    }

    /// Ends a wait now, or the next one if none runs (`stop()`, a scheduled task's start:
    /// `MainThreadWatchdog.wakeForTask()`, and a hang-watch scope the monitor must scan sooner).
    func wake() {
        guard descriptor >= 0 else { return }
        submit(ident: Self.stopIdent, filter: EVFILT_USER, flags: 0, fflags: UInt32(truncatingIfNeeded: NOTE_TRIGGER))
    }

    /// Registers one change with the kqueue, with no event list back.
    private func submit(ident: UInt, filter: Int32, flags: Int32, fflags: UInt32 = 0, data: Int = 0) {
        // SAFETY: udata is nil (no context pointer), and the change is a local live for the kevent call, which
        // reads that one change and, with a nil event list of count 0, writes nothing back.
        var change = unsafe kevent(ident: ident, filter: Int16(truncatingIfNeeded: filter), flags: UInt16(truncatingIfNeeded: flags),
                                   fflags: fflags, data: data, udata: nil)
        // SAFETY: as above.
        _ = unsafe kevent(descriptor, &change, 1, nil, 0, nil)
    }

    /// Blocks the calling thread (the watchdog's, never the main thread) until the timer fires,
    /// ``wake()`` runs or `nanos` pass; nil waits with no limit. A signal may end it early.
    func wait(nanos: UInt64?) {
        guard descriptor >= 0 else { return }
        var event = Darwin.kevent()
        if let nanos {
            var timeout = timespec(tv_sec: Int(clamping: nanos / 1_000_000_000), tv_nsec: Int(truncatingIfNeeded: nanos % 1_000_000_000))
            // concurrency-allow: the dedicated watchdog thread's bounded wait between stall checks; never the main thread.
            // SAFETY: kevent writes at most 1 event, the count given, into `event` and reads `timeout`, both locals
            // live for the call.
            _ = unsafe kevent(descriptor, nil, 0, &event, 1, &timeout)
        } else {
            // concurrency-allow: the dedicated watchdog thread parks while the main run loop sleeps; never the main thread.
            // SAFETY: kevent writes at most 1 event, the count given, into `event`, a local live for the call.
            _ = unsafe kevent(descriptor, nil, 0, &event, 1, nil)
        }
    }
}
