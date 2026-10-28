public import Foundation
internal import CmuxNextCompat

/// The Mac's thermal state, observed once for the app: the composition root's ``EnergyMonitor``
/// owns the one watch. It follows `ProcessInfo.thermalStateDidChangeNotification` (no polling),
/// as Chrome's thermal observer does (base/power_monitor/thermal_state_observer_mac.mm);
/// `override` replaces the system value (debug and tests).
@MainActor
public final class ThermalStateWatch {
    /// The thermal state now: `override` when set, else the system's.
    public private(set) var state: ProcessInfo.ThermalState
    /// Replaces the system state; nil follows macOS again.
    public var override: ProcessInfo.ThermalState? {
        didSet { update() }
    }
    /// Called with the new state after each change (the monitor, its one reader).
    var onChange: (@MainActor (ProcessInfo.ThermalState) -> Void)?

    private var systemState: ProcessInfo.ThermalState
    private let read: () -> ProcessInfo.ThermalState
    private var observation: MainActorObservation?

    /// A watch of the system's thermal state (``EnergyMonitor`` makes the app's one).
    public static func system() -> ThermalStateWatch {
        ThermalStateWatch(center: .default) { ProcessInfo.processInfo.thermalState }
    }

    /// Follows `read` each time `center` posts a thermal state change.
    public init(center: NotificationCenter, read: @escaping () -> ProcessInfo.ThermalState) {
        self.read = read
        systemState = read()
        state = systemState
        observation = MainActorObservation(ProcessInfo.thermalStateDidChangeNotification, center: center) { [weak self] in
            guard let self else { return }
            self.systemState = self.read()
            self.update()
        }
    }

    /// A fixed system state that only `override` changes (tests).
    public init(state: ProcessInfo.ThermalState) {
        read = { state }
        systemState = state
        self.state = state
    }

    private func update() {
        let next = override ?? systemState
        guard next != state else { return }
        state = next
        onChange?(next)
    }
}
