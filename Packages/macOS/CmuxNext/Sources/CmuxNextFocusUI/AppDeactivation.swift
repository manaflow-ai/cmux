#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

public extension NSApplication {
    /// Hands activation to the app `pid` names (the caller passes one, for example Finder's) and
    /// resigns active, as when a person works in another app; the windows stay where they are
    /// (`debug.focus {deactivate, activate_pid}`, the click-through proof). `deactivate()` alone
    /// left the app active when no other app took over. The caller names the app, so the app looks
    /// up no process.
    func deactivate(handingActivationTo pid: Int?) {
        if let pid, let pid = pid_t(exactly: pid), let other = NSRunningApplication(processIdentifier: pid) {
            yieldActivation(to: other)
            other.activate(from: .current, options: [])
        }
        deactivate()
    }
}
#endif
