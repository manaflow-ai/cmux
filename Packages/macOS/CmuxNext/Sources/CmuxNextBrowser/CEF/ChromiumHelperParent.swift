public import Darwin
import CmuxNextCompat

/// Whose children the Chromium helpers are, read from any thread: this app in process, the
/// attached Chromium Host in host mode, none while no host is attached. ``CEFRuntimeSource`` holds the one value;
/// the runtime writes it on the main actor as a host attaches and ends, and every ``ChromiumHelperProcess`` listing
/// reads it where it runs (the busy watchdog's thread, the memory sampler, the Energy Saver's work lane) without
/// waiting for the main thread. One atomic word: no lock.
public nonisolated final class ChromiumHelperParent: Sendable {
    /// The parent's pid; 0 for none.
    private let stored: Atomic<Int32>

    public init(_ pid: pid_t?) {
        stored = Atomic(pid ?? 0)
    }

    /// The parent now; nil while none runs the helpers (host mode with no host attached).
    public var pid: pid_t? {
        let pid = stored.load(ordering: .acquiring)
        return pid > 0 ? pid : nil
    }

    /// The runtime's write: the app in process, the attached host's pid, or nil.
    func set(_ pid: pid_t?) {
        stored.store(pid ?? 0, ordering: .releasing)
    }
}
