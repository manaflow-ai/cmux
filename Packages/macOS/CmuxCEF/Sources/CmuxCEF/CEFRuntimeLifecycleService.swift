import Foundation
internal import CmuxCEFShim

/// Owns the one process-wide CEF shutdown transition.
@MainActor
public final class CEFRuntimeLifecycleService {
    /// Creates a lifecycle service at the application composition boundary.
    public init() {}

    /// Stops CEF after browser owners have requested teardown.
    ///
    /// The operation is idempotent. External-pump timers stop first, and the C
    /// shim then closes outstanding browser windows before calling CEF's
    /// main-thread shutdown routine.
    public func shutdown() {
        guard CEFRuntime.isInitialized else { return }
        CEFMessagePump.stopDraining()
        cmux_cef_shutdown()
    }
}
