public import Foundation

/// The device's power budget for frames: Low Power Mode and the thermal state.
///
/// Chrome lowers frame rates the same way: Energy Saver throttles every frame sink
/// (`content/public/browser/frame_rate_throttling.h`, `StartThrottlingAllFrameSinks`, called from
/// `chrome/browser/performance_manager/user_tuning/battery_saver_mode_manager.cc`), and
/// `base::PowerThermalObserver` (`base/power_monitor/power_observer.h`) reports
/// `DeviceThermalState::kSerious` and `kCritical`. Chrome caps every sink at 30 Hz; cmux keeps
/// motion that follows the hand at full rate and pauses only what a person watches from the corner
/// of the eye (``FrameRateClass/limited(by:)``).
public struct PowerState: Sendable, Equatable {
    /// macOS Low Power Mode is on.
    public var isLowPowerMode: Bool
    /// The system's thermal state.
    public var thermalState: ProcessInfo.ThermalState

    /// - Parameters:
    ///   - isLowPowerMode: Low Power Mode is on.
    ///   - thermalState: The system's thermal state.
    public init(isLowPowerMode: Bool = false, thermalState: ProcessInfo.ThermalState = .nominal) {
        self.isLowPowerMode = isLowPowerMode
        self.thermalState = thermalState
    }

    /// Frame rates are capped: Low Power Mode is on, or the thermal state is serious or critical.
    public var capsFrameRate: Bool {
        isLowPowerMode || thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
}

extension FrameRateClass {
    /// The class a client of this class runs at under `power`; nil while `power` pauses it.
    ///
    /// With frame rates capped (``PowerState/capsFrameRate``): ``motion`` is unchanged (springs and
    /// drags follow the hand), ``ui`` stays at its 60 Hz cap, ``slow(_:)`` keeps its rate (it is
    /// already at most 30 a second), and ``ambient`` pauses, as when its view is hidden
    /// (LoopVisibility): a spinner or breathing dot gets no frames until the cap lifts.
    public func limited(by power: PowerState) -> FrameRateClass? {
        guard power.capsFrameRate else { return self }
        switch self {
        case .motion, .ui, .slow: return self
        case .ambient: return nil
        }
    }
}
