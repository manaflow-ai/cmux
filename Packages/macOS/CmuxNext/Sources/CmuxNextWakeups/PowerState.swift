public import Foundation

/// What the Mac's power and heat allow the display links now: the injected seam a ``DisplayClock``
/// reads (``DisplayClock/power``). The composition root sets it from its energy monitor (feature
/// `powerFrameCaps`); tests set a fake value. Nothing here reads `ProcessInfo` itself.
///
/// While it caps frames (``capsFrames``: Low Power Mode, or a serious or critical thermal state) an
/// ambient client (``FrameRate/isAmbient``) pauses off its scheduler, a ``FrameRate/ui`` client runs
/// its link at 60 Hz whatever ``DisplayClock/followsClientRates`` says, and a ``FrameRate/motion``
/// client is unchanged. The Core Animation loops follow it too: `LoopVisibility` takes its ambient
/// loops off their layers (the night sky, notice sweeps, now-playing bars) and the status indicators'
/// shared config holds their spinners still, until the cap lifts. Chrome reads the same two inputs: the OS battery saver turns its battery
/// saver on (components/performance_manager/user_tuning/battery_saver_mode_manager.cc), and
/// `PowerThermalObserver::DeviceThermalState::kSerious` (base/power_monitor/power_observer.h) is
/// where it starts shedding work.
public struct PowerState: Sendable, Equatable {
    /// macOS Low Power Mode is on.
    public var lowPowerMode: Bool
    /// The Mac's thermal state.
    public var thermal: ProcessInfo.ThermalState

    /// A state; the defaults are a cool Mac with Low Power Mode off.
    public init(lowPowerMode: Bool = false, thermal: ProcessInfo.ThermalState = .nominal) {
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
    }

    /// Low Power Mode off and the Mac cool: nothing is capped.
    public static let nominal = PowerState()

    /// Frames are capped: Low Power Mode is on, or the thermal state is serious or critical.
    public var capsFrames: Bool {
        lowPowerMode || thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    /// Whether a client at `rate` pauses: an ambient rate while frames are capped.
    public func pauses(_ rate: FrameRate) -> Bool { capsFrames && rate.isAmbient }
}

/// A subscription to a ``DisplayClock``'s ``DisplayClock/power`` changes. The clock holds it weakly:
/// releasing the token ends the subscription and releases its closure. ``cancel()`` ends it early.
@MainActor public final class PowerStateSubscription {
    /// The subscriber's name for diagnostics.
    public let owner: String
    let onChange: @MainActor (PowerState) -> Void
    private weak var clock: DisplayClock?

    init(owner: String, clock: DisplayClock, onChange: @escaping @MainActor (PowerState) -> Void) {
        self.owner = owner
        self.clock = clock
        self.onChange = onChange
    }

    /// The clock's power state now; ``PowerState/nominal`` once the clock is gone or it is cancelled.
    public var power: PowerState { clock?.power ?? .nominal }

    /// Whether the subscription has not been cancelled.
    var isActive: Bool { clock != nil }

    /// Ends the subscription now.
    public func cancel() {
        clock?.removePowerSubscription(self)
        clock = nil
    }
}

/// A ``PowerStateSubscription`` a ``DisplayClock`` holds without keeping it alive.
struct WeakPowerSubscription {
    weak var subscription: PowerStateSubscription?
}

extension DisplayClock {
    /// Calls `onChange` after each change of ``power`` until the returned subscription is released
    /// or cancelled. Released subscriptions are dropped here too, so the list stays the live ones.
    public func subscribePower(owner: String, _ onChange: @escaping @MainActor (PowerState) -> Void) -> PowerStateSubscription {
        let subscription = PowerStateSubscription(owner: owner, clock: self, onChange: onChange)
        powerSubscriptions.removeAll { $0.subscription == nil }
        powerSubscriptions.append(WeakPowerSubscription(subscription: subscription))
        return subscription
    }

    /// Owners of the live ``power`` subscriptions (debug.wakeups and tests).
    public var powerSubscribers: [String] { powerSubscriptions.compactMap(\.subscription?.owner) }

    func removePowerSubscription(_ subscription: PowerStateSubscription) {
        powerSubscriptions.removeAll { $0.subscription == nil || $0.subscription === subscription }
    }

    /// Tells every live subscription the new ``power``, dropping released ones. It walks a copy, so a
    /// subscriber may subscribe or cancel from its callback.
    func notifyPowerSubscribers() {
        powerSubscriptions.removeAll { $0.subscription == nil }
        for subscription in powerSubscriptions.compactMap(\.subscription) { subscription.onChange(power) }
    }
}
