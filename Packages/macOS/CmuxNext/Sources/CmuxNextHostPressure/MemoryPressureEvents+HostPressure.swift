public import CmuxNextCompat

extension MemoryPressureEvents {
    /// This feed as ``HostPressureMonitor`` subscribes to it: each level in the host budget's
    /// words, until the returned call cancels the registration.
    ///
    /// ```swift
    /// HostPressureMonitor(source: LocalHostPressureSource(), memoryPressure: services.memoryPressure.hostPressureSubscription)
    /// ```
    public var hostPressureSubscription: HostPressureMonitor.MemoryPressureSubscription {
        { [self] handler in
            let registration = observe { level in handler(HostMemoryPressure(level)) }
            return { registration.cancel() }
        }
    }
}

extension HostMemoryPressure {
    /// The host budget's name for the app's memory pressure level.
    public init(_ level: MemoryPressureLevel) {
        switch level {
        case .normal: self = .normal
        case .warning: self = .warn
        case .critical: self = .critical
        }
    }
}
