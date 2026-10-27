public import Foundation
internal import CmuxNextCompat

/// macOS Low Power Mode, observed once for the app: the composition root's ``EnergyMonitor``
/// owns the one instance and hands it out by init. It follows
/// `NSProcessInfoPowerStateDidChange` (no polling) with one main-queue observer, as
/// ``ThermalStateWatch`` follows the thermal state (Chrome's
/// base/power_monitor/power_monitor_device_source_mac.mm observes the same notice once);
/// `override` replaces the system value (the `debug.low_power_mode` socket method and tests).
@MainActor
public final class LowPowerMode {
    /// An observer of the system power state (``EnergyMonitor`` makes the app's one).
    public static func system() -> LowPowerMode {
        LowPowerMode(center: .default) { ProcessInfo.processInfo.isLowPowerModeEnabled }
    }

    /// Whether Low Power Mode is on: `override` when set, else the system value.
    public private(set) var isEnabled: Bool
    /// Replaces the system value; nil follows macOS again.
    public var override: Bool? {
        didSet { update() }
    }

    private var systemEnabled: Bool
    private let read: () -> Bool
    private let handlers = MainActorHandlers<Bool>()
    private var observation: MainActorObservation?

    /// Follows `read` each time `center` posts a power state change.
    public init(center: NotificationCenter, read: @escaping () -> Bool) {
        self.read = read
        systemEnabled = read()
        isEnabled = systemEnabled
        observation = MainActorObservation(.NSProcessInfoPowerStateDidChange, center: center) { [weak self] in
            guard let self else { return }
            self.systemEnabled = self.read()
            self.update()
        }
    }

    /// A fixed system value that only `override` changes (tests).
    public init(enabled: Bool) {
        read = { enabled }
        systemEnabled = enabled
        isEnabled = enabled
    }

    /// Calls `handler` with the new value each time Low Power Mode turns on
    /// or off, until the returned observation is released (on any thread) or cancelled.
    public func observe(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) -> LowPowerModeObservation {
        LowPowerModeObservation(handlers.add(handler))
    }

    private func update() {
        let enabled = override ?? systemEnabled
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        handlers.call(enabled)
    }
}
