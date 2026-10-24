import CmuxNextCompat
import Darwin
import MachO

/// When dyld last removed an image from this process (`CLOCK_UPTIME_RAW` nanoseconds), from a
/// `_dyld_register_func_for_remove_image` callback.
///
/// The watchdog samples return addresses during a stall and they are resolved later, on a
/// utility task. If an image was unloaded in between, another image may now sit at those
/// addresses, so the frame would name the wrong image and offset. ``HangReportCollector`` drops
/// such a stack's frames (all `other`) instead: ``removed(since:)`` is one atomic load.
public nonisolated struct DyldImageUnloads: Sendable {
    /// Makes the value from its parts.
    public init() {}

    /// Starts the bookkeeping (once per process; later calls do nothing). Before it runs,
    /// ``removed(since:)`` treats every sample as unsafe.
    public func install() {
        guard installed.exchange(true, ordering: .acquiringAndReleasing) == false else { return }
        _dyld_register_func_for_remove_image(noteImageRemoved)
        ready.store(true, ordering: .releasing)
    }

    /// Whether an image was removed at or after `uptimeNanos` (or the bookkeeping is not running).
    public func removed(since uptimeNanos: UInt64) -> Bool {
        guard ready.load(ordering: .acquiring) else { return true }
        return lastImageRemoval.load(ordering: .acquiring) >= uptimeNanos
    }
}

// The process's one dyld callback state: a C callback cannot capture, so it writes a global.
private let lastImageRemoval = Atomic<UInt64>(0)
private let installed = Atomic<Bool>(false)
private let ready = Atomic<Bool>(false)

/// dyld calls this under its lock for each image it unloads: one atomic store, nothing else.
private func noteImageRemoved(_ header: UnsafePointer<mach_header>?, _ slide: Int) {
    lastImageRemoval.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .releasing)
}
