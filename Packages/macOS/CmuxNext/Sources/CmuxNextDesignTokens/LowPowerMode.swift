public import Foundation

/// macOS Low Power Mode, observed once for the app. It follows
/// `NSProcessInfoPowerStateDidChange` (no polling); `override` replaces the
/// system value (the `debug.low_power_mode` socket method and tests).
@MainActor
public final class LowPowerMode {
    /// The app's observer of the system power state.
    public static let system = LowPowerMode(center: .default) { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Whether Low Power Mode is on: `override` when set, else the system value.
    public private(set) var isEnabled: Bool
    /// Replaces the system value; nil follows macOS again.
    public var override: Bool? {
        didSet { update() }
    }

    private var systemEnabled: Bool
    private let read: () -> Bool
    /// The registered observations, weakly: one that is released stops its calls without a deinit
    /// (it deallocates with its handler; its entry reads nil and goes at the next change).
    private var observations: [ObjectIdentifier: WeakObservation] = [:]
    private var notifications: Task<Void, Never>?

    /// Follows `read` each time `center` posts a power state change.
    public init(center: NotificationCenter, read: @escaping () -> Bool) {
        self.read = read
        systemEnabled = read()
        isEnabled = systemEnabled
        notifications = Task { [weak self, center] in
            for await _ in center.notifications(named: .NSProcessInfoPowerStateDidChange) {
                guard let self else { return }
                self.systemEnabled = self.read()
                self.update()
            }
        }
    }

    /// A fixed system value that only `override` changes (tests).
    public init(enabled: Bool) {
        read = { enabled }
        systemEnabled = enabled
        isEnabled = enabled
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Sendable cleanup only (`Task.cancel()`), so it runs on whatever thread releases this object.
    nonisolated deinit {
        notifications?.cancel()
    }

    /// Calls `handler` with the new value each time Low Power Mode turns on
    /// or off, until the returned observation is released or cancelled.
    public func observe(_ handler: @escaping (Bool) -> Void) -> LowPowerModeObservation {
        let observation = LowPowerModeObservation(source: self, handler: handler)
        observations[ObjectIdentifier(observation)] = WeakObservation(value: observation)
        return observation
    }

    fileprivate func stop(_ observation: LowPowerModeObservation) {
        observations[ObjectIdentifier(observation)] = nil
    }

    private func update() {
        let enabled = override ?? systemEnabled
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        observations = observations.filter { $0.value.value != nil }
        // Every live observation, held for the whole pass: a handler that cancels another one does not
        // skip it in this pass.
        for observation in observations.values.compactMap(\.value) { observation.handler(enabled) }
    }
}

/// One `LowPowerMode.observe` registration; releasing it (on any thread) or ``cancel()`` stops the calls.
@MainActor
public final class LowPowerModeObservation {
    private weak var source: LowPowerMode?
    fileprivate let handler: (Bool) -> Void

    fileprivate init(source: LowPowerMode, handler: @escaping (Bool) -> Void) {
        self.source = source
        self.handler = handler
    }

    /// Stops the calls.
    public func cancel() {
        source?.stop(self)
    }
}

/// A registered observation, held weakly by its ``LowPowerMode``.
private struct WeakObservation {
    weak var value: LowPowerModeObservation?
}
