/// Orders mobile-host transport startup so the required TCP listener is
/// available before optional Iroh policy and credential work is scheduled.
///
/// `scheduleIroh` must enqueue asynchronous activation and return immediately.
/// Keeping that boundary synchronous makes it impossible for a relay-policy or
/// Keychain suspension to delay the existing TCP listener.
public struct CmxIrohTCPFirstActivation {
    /// Creates a TCP-first activation sequencer.
    public init() {}

    /// Starts the required TCP listener synchronously, then schedules the
    /// optional Iroh activation work.
    ///
    /// - Parameters:
    ///   - startTCP: Synchronously starts the required TCP listener.
    ///   - scheduleIroh: Enqueues asynchronous Iroh activation and returns
    ///     immediately without blocking on policy or credential work.
    public func start(
        startTCP: () -> Void,
        scheduleIroh: () -> Void
    ) {
        startTCP()
        scheduleIroh()
    }
}
