public import CmuxNextCompat

extension MemoryPressureEvents {
    /// This feed as ``HostPressureMonitor`` subscribes to it: ``currentLevel`` when it subscribes,
    /// then each change, in the host budget's words, until the returned `end` cancels the
    /// registration. It registers before it reads the level, so no change falls between the two.
    ///
    /// ```swift
    /// HostPressureMonitor(source: LocalHostPressureSource(), memoryPressure: services.memoryPressure.hostPressureSubscription)
    /// ```
    public var hostPressureSubscription: HostPressureMonitor.MemoryPressureSubscription {
        { [self] handler in
            let registration = observe { level in handler(HostMemoryPressure(level)) }
            return (HostMemoryPressure(currentLevel), { registration.cancel() })
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
