internal import CmuxNextCompat

/// One `LowPowerMode.observe` registration; releasing it, on any thread, or
/// calling ``cancel()`` stops the calls.
public nonisolated final class LowPowerModeObservation: Sendable {
    private let registration: MainActorHandlerRegistration<Bool>

    init(_ registration: MainActorHandlerRegistration<Bool>) {
        self.registration = registration
    }

    /// Stops the calls.
    public func cancel() {
        registration.cancel()
    }
}
