import Darwin

/// The watchdog thread's only wait (``MainThreadWatchdog``): a kqueue holding one one-shot
/// timer, which the main thread arms when its run loop wakes and deletes before it sleeps, and
/// one user event that `stop()` and a scheduled task's start trigger.
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
        var stop = kevent(ident: Self.stopIdent, filter: Int16(truncatingIfNeeded: EVFILT_USER), flags: UInt16(truncatingIfNeeded: EV_ADD | EV_CLEAR),
                          fflags: 0, data: 0, udata: nil)
        _ = kevent(descriptor, &stop, 1, nil, 0, nil)
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// False when the kqueue could not be made.
    var isAvailable: Bool { descriptor >= 0 }

    /// Fires once, `nanos` from now, unless ``disarm()`` comes first (the main run loop woke).
    func arm(afterNanos nanos: UInt64) {
        guard descriptor >= 0 else { return }
        var change = kevent(ident: Self.timerIdent, filter: Int16(truncatingIfNeeded: EVFILT_TIMER), flags: UInt16(truncatingIfNeeded: EV_ADD | EV_ONESHOT),
                            fflags: UInt32(truncatingIfNeeded: NOTE_NSECONDS), data: Int(clamping: nanos), udata: nil)
        _ = kevent(descriptor, &change, 1, nil, 0, nil)
    }

    /// Drops a pending or fired timer (the main run loop is about to sleep). None is fine (ENOENT).
    func disarm() {
        guard descriptor >= 0 else { return }
        var change = kevent(ident: Self.timerIdent, filter: Int16(truncatingIfNeeded: EVFILT_TIMER), flags: UInt16(truncatingIfNeeded: EV_DELETE),
                            fflags: 0, data: 0, udata: nil)
        _ = kevent(descriptor, &change, 1, nil, 0, nil)
    }

    /// Ends a wait now, or the next one if none runs (`stop()`, and a scheduled task's start:
    /// `MainThreadWatchdog.wakeForTask()`).
    func wake() {
        guard descriptor >= 0 else { return }
        var change = kevent(ident: Self.stopIdent, filter: Int16(truncatingIfNeeded: EVFILT_USER), flags: 0,
                            fflags: UInt32(truncatingIfNeeded: NOTE_TRIGGER), data: 0, udata: nil)
        _ = kevent(descriptor, &change, 1, nil, 0, nil)
    }

    /// Blocks the calling thread (the watchdog's, never the main thread) until the timer fires,
    /// ``wake()`` runs or `nanos` pass; nil waits with no limit. A signal may end it early.
    func wait(nanos: UInt64?) {
        guard descriptor >= 0 else { return }
        var event = Darwin.kevent()
        if let nanos {
            var timeout = timespec(tv_sec: Int(clamping: nanos / 1_000_000_000), tv_nsec: Int(truncatingIfNeeded: nanos % 1_000_000_000))
            // concurrency-allow: the dedicated watchdog thread's bounded wait between stall checks; never the main thread.
            _ = kevent(descriptor, nil, 0, &event, 1, &timeout)
        } else {
            // concurrency-allow: the dedicated watchdog thread parks while the main run loop sleeps; never the main thread.
            _ = kevent(descriptor, nil, 0, &event, 1, nil)
        }
    }
}
