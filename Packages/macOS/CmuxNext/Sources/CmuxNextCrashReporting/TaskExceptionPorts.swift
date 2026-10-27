import CmuxNextCompat
import Darwin

/// The task's Mach exception ports for the exceptions Sentry's crash
/// monitor takes, as they were before Sentry started, so a fatal-signal
/// handler can give them back before a fault runs again.
///
/// Why (2026-10-20 NIGHTLY freezes, pids 52838 and 98698): Sentry 9.28's
/// Mach exception monitor (`SentryCrashMonitor_MachException.c`) restores the
/// previous ports only when it handles an exception while it is enabled. An
/// uncaught Objective-C exception goes the other way: Sentry's
/// `reportException:` hook records it and turns every monitor off
/// (`sentrycrashcm_handleException`), and turning the Mach monitor off leaves
/// its port registered on purpose. AppKit then traps (`brk` in
/// `_crashOnException:`). The primary handler thread receives that
/// EXC_BREAKPOINT while turned off, replies "not handled" and exits, without
/// restoring the ports and without waking the secondary thread. The kernel
/// sends SIGTRAP; `AppRunMarker`'s handler records it and returns so the
/// trap runs again under SIG_DFL (for the system crash report). The second
/// EXC_BREAKPOINT goes to Sentry's port again, which nothing receives any
/// more, and the trapping thread waits for a reply forever: 0% CPU until
/// Force Quit. Giving the ports back first sends the second trap to the
/// system's handler, so the process ends with its report.
enum TaskExceptionPorts {
    /// No port (`MACH_PORT_NULL`).
    static let nullPort = mach_port_t(0)
    /// The exceptions Sentry's Mach monitor registers for.
    static let sentryMask = exception_mask_t(
        EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_SOFTWARE | EXC_MASK_BREAKPOINT)

    /// The ports ``captureBeforeSentry()`` saved, not yet published to the
    /// crash path; ``noteSentryStarted(_:)`` publishes or frees them.
    struct Capture {
        fileprivate let saved: SavedExceptionPorts
    }

    /// Saves the task's current ports for ``sentryMask``. Call once, right
    /// before `SentrySDK.start`, on the thread that starts it, and pass the
    /// result to ``noteSentryStarted(_:)`` right after.
    static func captureBeforeSentry() -> Capture? {
        // SAFETY: savedExceptionPorts is published once, on this (main) thread; see its declaration.
        guard unsafe savedExceptionPorts == nil else { return nil }
        let capacity = Int(EXC_TYPES_COUNT)
        // SAFETY: four uninitialized arrays of EXC_TYPES_COUNT elements; `saved` below takes ownership of them and
        // frees them (deallocate) on failure or when it is not published; task_get_exception_ports fills them.
        let masks = unsafe UnsafeMutablePointer<exception_mask_t>.allocate(capacity: capacity)
        let ports = unsafe UnsafeMutablePointer<mach_port_t>.allocate(capacity: capacity)
        let behaviors = unsafe UnsafeMutablePointer<exception_behavior_t>.allocate(capacity: capacity)
        let flavors = unsafe UnsafeMutablePointer<thread_state_flavor_t>.allocate(capacity: capacity)
        var count = mach_msg_type_number_t(capacity)
        // SAFETY: the four arrays were just allocated with EXC_TYPES_COUNT elements each; `saved` owns them.
        let saved = unsafe SavedExceptionPorts(count: 0, masks: masks, ports: ports, behaviors: behaviors, flavors: flavors,
                                               sentryPort: nullPort)
        // SAFETY: task_get_exception_ports writes at most `count` (EXC_TYPES_COUNT, each array's capacity) entries
        // into each array and the number written into `count`, a local live for the call.
        guard unsafe task_get_exception_ports(mach_task_self_, sentryMask, masks, &count, ports, behaviors, flavors) == KERN_SUCCESS else {
            saved.deallocate()
            return nil
        }
        return Capture(saved: saved.counting(Int(count)))
    }

    /// Publishes `capture` to the crash path with the port Sentry registered.
    /// Call right after `SentrySDK.start`, on the same thread. Nothing is
    /// kept when Sentry registered no port (a debugger is attached, or its
    /// Mach monitor is off): the crash path then has nothing to give back.
    static func noteSentryStarted(_ capture: Capture?) {
        guard let capture else { return }
        let current = currentBreakpointPort()
        guard current != nullPort, current != capture.saved.breakpointPort else {
            capture.saved.deallocate()
            return
        }
        SavedExceptionPorts.publish(capture.saved.registeredBySentry(current))
    }

    /// Whether the task's EXC_BREAKPOINT port is still the one Sentry
    /// registered at start.
    static var sentryOwnsPorts: Bool {
        guard let saved = SavedExceptionPorts.current else { return false }
        return currentBreakpointPort() == saved.sentryPort
    }

    /// Puts back the ports saved by ``captureBeforeSentry()`` while Sentry's
    /// port is still registered. Async-signal-safe: Mach calls on memory
    /// allocated at launch, no allocation, no locks. Fatal-signal handlers
    /// and the crash deadline call it; the process is ending.
    static func restoreIfSentryOwned() {
        guard let saved = SavedExceptionPorts.current, currentBreakpointPort() == saved.sentryPort else { return }
        let task = mach_task_self_
        // Clear every bit first: one the earlier owner did not have must not
        // stay on Sentry's port.
        _ = task_set_exception_ports(task, sentryMask, nullPort,
                                     exception_behavior_t(EXCEPTION_DEFAULT), thread_state_flavor_t(THREAD_STATE_NONE))
        // A plain loop: no generic Range code in a signal handler (Debug builds).
        var index = 0
        while index < saved.count {
            // SAFETY: index < saved.count, inside the published arrays (SavedExceptionPorts), which are never freed.
            if unsafe saved.ports[index] != nullPort {
                // SAFETY: as above.
                _ = unsafe task_set_exception_ports(task, saved.masks[index], saved.ports[index], saved.behaviors[index], saved.flavors[index])
            }
            index += 1
        }
    }

    /// The port of the task's EXC_BREAKPOINT entry (one entry for one bit).
    private static func currentBreakpointPort() -> mach_port_t {
        var mask = exception_mask_t(0)
        var count = mach_msg_type_number_t(1)
        var port = nullPort
        var behavior = exception_behavior_t(0)
        var flavor = thread_state_flavor_t(0)
        // SAFETY: with `count` 1 the call writes at most one entry into each of the five locals, live for the call.
        let result = unsafe task_get_exception_ports(mach_task_self_, exception_mask_t(EXC_MASK_BREAKPOINT),
                                              &mask, &count, &port, &behavior, &flavor)
        guard result == KERN_SUCCESS, count == 1 else { return nullPort }
        // The call added a send-right reference; give it back (the name stays
        // valid: the task keeps the handler's right while it is registered).
        if port != nullPort { _ = mach_port_deallocate(mach_task_self_, port) }
        return port
    }
}

/// The ports saved before Sentry started and the port Sentry registered, as
/// the crash path reads them: arrays allocated at launch and never freed once
/// published, so a fatal-signal handler reads them without allocating.
// SAFETY (the arrays): the four pointers are arrays of EXC_TYPES_COUNT elements that captureBeforeSentry()
// allocated for this value, `count` (at most EXC_TYPES_COUNT) of them filled by task_get_exception_ports; every read
// is below `count`. They are freed only through ``deallocate()``, before any publish, and never once published.
@safe private struct SavedExceptionPorts {
    let count: Int
    let masks: UnsafeMutablePointer<exception_mask_t>
    let ports: UnsafeMutablePointer<mach_port_t>
    let behaviors: UnsafeMutablePointer<exception_behavior_t>
    let flavors: UnsafeMutablePointer<thread_state_flavor_t>
    /// Sentry's EXC_BREAKPOINT port; never null once published.
    let sentryPort: mach_port_t

    func counting(_ count: Int) -> SavedExceptionPorts {
        // SAFETY: as above (the arrays); `count` is the number task_get_exception_ports filled.
        unsafe SavedExceptionPorts(count: count, masks: masks, ports: ports, behaviors: behaviors, flavors: flavors, sentryPort: sentryPort)
    }

    func registeredBySentry(_ port: mach_port_t) -> SavedExceptionPorts {
        // SAFETY: as above (the arrays).
        unsafe SavedExceptionPorts(count: count, masks: masks, ports: ports, behaviors: behaviors, flavors: flavors, sentryPort: port)
    }

    /// The saved EXC_BREAKPOINT port.
    var breakpointPort: mach_port_t {
        var index = 0
        while index < count {
            // SAFETY: as above (the arrays): index < count.
            if unsafe masks[index] & exception_mask_t(EXC_MASK_BREAKPOINT) != 0 { return unsafe ports[index] }
            index += 1
        }
        return TaskExceptionPorts.nullPort
    }

    func deallocate() {
        // SAFETY: as above (the arrays): called once, on a value that was never published.
        unsafe masks.deallocate()
        // SAFETY: as above.
        unsafe ports.deallocate()
        // SAFETY: as above.
        unsafe behaviors.deallocate()
        // SAFETY: as above.
        unsafe flavors.deallocate()
    }

    /// The published ports, nil before ``publish(_:)``. Async-signal-safe: one
    /// load, an acquiring fence that pairs with the publish's releasing one,
    /// and a copy of the block's words.
    static var current: SavedExceptionPorts? {
        // SAFETY: a non-nil value is the block publish() initialized and never frees (see the declaration).
        guard let block = unsafe savedExceptionPorts else { return nil }
        atomicFence(ordering: .acquiring)
        // SAFETY: as above.
        return unsafe block.pointee
    }

    /// Copies `saved` into a block kept for the process's life and publishes
    /// its address after a releasing fence (main thread, once, at launch).
    static func publish(_ saved: SavedExceptionPorts) {
        // SAFETY: allocates one element and initializes it at once; the block is never freed once published.
        let block = unsafe UnsafeMutablePointer<SavedExceptionPorts>.allocate(capacity: 1)
        unsafe block.initialize(to: saved)
        atomicFence(ordering: .releasing)
        // SAFETY: published once, on the main thread at launch; see the declaration.
        unsafe savedExceptionPorts = block
    }
}

// Threads: published once on the main thread at launch, right after Sentry starts (CrashReporter.start), before any
// fault can need it; read by fatal-signal handlers on whichever thread faulted and by the crash deadline thread. One
// aligned word with a constant initial value; the store follows a releasing fence and every load is followed by an
// acquiring one (SavedExceptionPorts.publish and .current). No lock: a signal handler that waits for a lock the
// interrupted thread holds never returns, and os_unfair_lock is not async-signal-safe; no Atomic: its lazy initializer
// would run in the handler.
// crash-allow: async-signal-safe global, published once on the main thread, read by signal handlers (why no lock: above).
nonisolated(unsafe) private var savedExceptionPorts: UnsafeMutablePointer<SavedExceptionPorts>?
