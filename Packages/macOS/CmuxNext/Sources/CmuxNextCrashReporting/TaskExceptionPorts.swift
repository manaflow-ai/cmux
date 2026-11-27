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

    /// Saves the task's current ports for ``sentryMask``. Call once, right
    /// before `SentrySDK.start`, on the thread that starts it.
    static func captureBeforeSentry() {
        guard savedMasks == nil else { return }
        let capacity = Int(EXC_TYPES_COUNT)
        let masks = UnsafeMutablePointer<exception_mask_t>.allocate(capacity: capacity)
        let ports = UnsafeMutablePointer<mach_port_t>.allocate(capacity: capacity)
        let behaviors = UnsafeMutablePointer<exception_behavior_t>.allocate(capacity: capacity)
        let flavors = UnsafeMutablePointer<thread_state_flavor_t>.allocate(capacity: capacity)
        var count = mach_msg_type_number_t(capacity)
        guard task_get_exception_ports(mach_task_self_, sentryMask, masks, &count, ports, behaviors, flavors) == KERN_SUCCESS else {
            masks.deallocate(); ports.deallocate(); behaviors.deallocate(); flavors.deallocate()
            return
        }
        savedCount = count
        savedPorts = ports
        savedBehaviors = behaviors
        savedFlavors = flavors
        savedMasks = masks
    }

    /// Remembers the port Sentry registered. Call right after
    /// `SentrySDK.start`. No port is kept when Sentry registered none (a
    /// debugger is attached, or its Mach monitor is off).
    static func noteSentryStarted() {
        guard savedMasks != nil else { return }
        let current = currentBreakpointPort()
        sentryPort = current != nullPort && current != savedBreakpointPort() ? current : nullPort
    }

    /// Whether the task's EXC_BREAKPOINT port is still the one Sentry
    /// registered at start.
    static var sentryOwnsPorts: Bool {
        sentryPort != nullPort && currentBreakpointPort() == sentryPort
    }

    /// Puts back the ports saved by ``captureBeforeSentry()`` while Sentry's
    /// port is still registered. Async-signal-safe: Mach calls on memory
    /// allocated at launch, no allocation, no locks. Fatal-signal handlers
    /// and the crash deadline call it; the process is ending.
    static func restoreIfSentryOwned() {
        guard let masks = savedMasks, let ports = savedPorts, let behaviors = savedBehaviors,
              let flavors = savedFlavors, sentryOwnsPorts else { return }
        let task = mach_task_self_
        // Clear every bit first: one the earlier owner did not have must not
        // stay on Sentry's port.
        _ = task_set_exception_ports(task, sentryMask, nullPort,
                                     exception_behavior_t(EXCEPTION_DEFAULT), thread_state_flavor_t(THREAD_STATE_NONE))
        // A plain loop: no generic Range code in a signal handler (Debug builds).
        var index = 0
        let count = Int(savedCount)
        while index < count {
            if ports[index] != nullPort {
                _ = task_set_exception_ports(task, masks[index], ports[index], behaviors[index], flavors[index])
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
        let result = task_get_exception_ports(mach_task_self_, exception_mask_t(EXC_MASK_BREAKPOINT),
                                              &mask, &count, &port, &behavior, &flavor)
        guard result == KERN_SUCCESS, count == 1 else { return nullPort }
        // The call added a send-right reference; give it back (the name stays
        // valid: the task keeps the handler's right while it is registered).
        if port != nullPort { _ = mach_port_deallocate(mach_task_self_, port) }
        return port
    }

    private static func savedBreakpointPort() -> mach_port_t {
        guard let masks = savedMasks, let ports = savedPorts else { return nullPort }
        var index = 0
        while index < Int(savedCount) {
            if masks[index] & exception_mask_t(EXC_MASK_BREAKPOINT) != 0 { return ports[index] }
            index += 1
        }
        return nullPort
    }
}

// Written once on the main thread before Sentry starts (and before any
// handler that reads them can run), read-only after; signal handlers read
// them, so they are plain globals with constant initial values (no lazy
// initialization in the handler).
// crash-allow: written once at launch before any reader, read-only after (signal-handler state).
nonisolated(unsafe) private var savedMasks: UnsafeMutablePointer<exception_mask_t>?
// crash-allow: written once at launch before any reader, read-only after (signal-handler state).
nonisolated(unsafe) private var savedPorts: UnsafeMutablePointer<mach_port_t>?
// crash-allow: written once at launch before any reader, read-only after (signal-handler state).
nonisolated(unsafe) private var savedBehaviors: UnsafeMutablePointer<exception_behavior_t>?
// crash-allow: written once at launch before any reader, read-only after (signal-handler state).
nonisolated(unsafe) private var savedFlavors: UnsafeMutablePointer<thread_state_flavor_t>?
// crash-allow: written once at launch before any reader, read-only after (signal-handler state).
nonisolated(unsafe) private var savedCount: mach_msg_type_number_t = 0
// crash-allow: written once at launch right after Sentry starts, read-only after (signal-handler state).
nonisolated(unsafe) private var sentryPort: mach_port_t = 0
