public import Foundation

/// Stores the concrete dependencies used by ``FleetEngine``.
@MainActor
public struct FleetEngineDependencies {
    /// The app-side actuation seam.
    public var actuator: any FleetActuating

    /// The app-side world-reading seam.
    public var world: any FleetWorldReading

    /// The timer scheduling seam.
    public var timers: any FleetTimerScheduling

    /// The process-watching seam.
    public var processWatcher: any FleetProcessWatching

    /// The persistence seam.
    public var persistence: any FleetPersisting

    /// Returns the current time.
    public var now: @Sendable () -> Date

    /// The shared reconcile interval in milliseconds.
    public var reconcileIntervalMS: Int

    /// The idle-prompt grace window in milliseconds.
    public var promptIdleGraceMS: Int

    /// Receives debug log lines.
    public var debugLog: @Sendable (String) -> Void

    /// Creates Fleet engine dependencies.
    /// - Parameters:
    ///   - actuator: The app-side actuation seam.
    ///   - world: The app-side world-reading seam.
    ///   - timers: The timer scheduling seam.
    ///   - processWatcher: The process-watching seam.
    ///   - persistence: The persistence seam.
    ///   - now: Returns the current time.
    ///   - reconcileIntervalMS: The shared reconcile interval in milliseconds.
    ///   - promptIdleGraceMS: The idle-prompt grace window in milliseconds.
    ///   - debugLog: Receives debug log lines.
    public init(
        actuator: any FleetActuating,
        world: any FleetWorldReading,
        timers: any FleetTimerScheduling,
        processWatcher: any FleetProcessWatching,
        persistence: any FleetPersisting,
        now: @escaping @Sendable () -> Date = { Date() },
        reconcileIntervalMS: Int = 30_000,
        promptIdleGraceMS: Int = 120_000,
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.actuator = actuator
        self.world = world
        self.timers = timers
        self.processWatcher = processWatcher
        self.persistence = persistence
        self.now = now
        self.reconcileIntervalMS = reconcileIntervalMS
        self.promptIdleGraceMS = promptIdleGraceMS
        self.debugLog = debugLog
    }
}
