/// Orders mobile-host transport startup so the required TCP listener becomes
/// available before optional Iroh policy and credential work is scheduled.
public struct CmxIrohTCPFirstActivation {
    private let startTCP: () -> Void
    private let scheduleIroh: () -> Void

    /// Creates an activation step with explicit transport dependencies.
    ///
    /// `scheduleIroh` must enqueue asynchronous activation and return
    /// immediately. Keeping that boundary synchronous prevents relay-policy or
    /// Keychain suspension from delaying the existing TCP listener.
    /// - Parameters:
    ///   - startTCP: Starts the required TCP listener synchronously.
    ///   - scheduleIroh: Schedules optional Iroh activation without awaiting it.
    public init(
        startTCP: @escaping () -> Void,
        scheduleIroh: @escaping () -> Void
    ) {
        self.startTCP = startTCP
        self.scheduleIroh = scheduleIroh
    }

    /// Starts TCP, then schedules optional Iroh activation.
    public func start() {
        startTCP()
        scheduleIroh()
    }
}
