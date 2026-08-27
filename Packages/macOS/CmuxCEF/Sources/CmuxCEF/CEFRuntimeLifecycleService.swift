import Foundation
internal import CmuxCEFShim

/// Owns the one process-wide CEF shutdown transition.
@MainActor
public final class CEFRuntimeLifecycleService {
    /// Creates a lifecycle service at the application composition boundary.
    public init() {}

    /// Stops CEF after browser owners have requested teardown.
    ///
    /// The operation is idempotent. `startDraining()` first invalidates any
    /// scheduled external-pump timer, and the C shim then closes outstanding
    /// browser windows before calling CEF's main-thread shutdown routine.
    public func shutdown() {
        guard CEFRuntime.isInitialized else { return }
        CEFMessagePump.startDraining()
        cmux_cef_shutdown()
    }
}
