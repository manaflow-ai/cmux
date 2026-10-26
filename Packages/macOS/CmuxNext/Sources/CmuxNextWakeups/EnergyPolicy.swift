import CmuxNextCompat

/// What Energy Saver asks of every scheduler now: one value the composition root resolves from the
/// power inputs (`CmuxNextEnergy`) and publishes through an ``EnergyPolicySource``. Consumers in
/// core targets read this value; none of them imports AppKit's or IOKit's power APIs.
///
/// It follows Chrome's battery saver (components/performance_manager/user_tuning/
/// battery_saver_mode_manager.cc): frame sinks throttled to 30 Hz, and wake-ups aligned to 32 ms
/// (content/child/child_thread_impl.cc `SetBatterySaverMode` ->
/// `MessagePump::OverrideAlignWakeUpsState(true, 32 ms)`) in place of the 8 ms default leeway
/// (base/task/task_features.h `kDefaultLeeway`). Background polls stretch by ``pollStretch``, a
/// cmux addition (Chrome has no app-level polls to stretch).
public struct EnergyPolicy: Sendable, Equatable {
    /// Why the saver is on.
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        /// macOS Low Power Mode is on.
        case lowPowerMode
        /// On battery with little charge left.
        case battery
        /// On battery and the Mac is hot.
        case thermal
        /// The `energy.saver` setting asks for it.
        case setting
    }

    /// The frame rate cap of ambient frames and web pages under the saver (Chrome's 30 Hz frame sink throttle).
    public static let saverFrameRate = 30
    /// How much longer background polls wait under the saver.
    public static let saverPollStretch = 4

    /// Energy Saver is on.
    public let isSaver: Bool
    /// Why the saver is on; nil while it is off.
    public let reason: Reason?
    /// The grid and leeway of flexible sub-second wake-ups: ``WakeLeeway/defaultAlignment`` (8 ms),
    /// ``WakeLeeway/saverAlignment`` (32 ms) under the saver.
    public let wakeAlignment: Duration
    /// The highest frame rate of ambient frame clients; nil while uncapped.
    public let ambientMaxFPS: Int?
    /// The highest frame rate of web pages the person does not interact with; nil while uncapped.
    public let webFrameRate: Int?
    /// The factor background polls multiply their interval by (1, 4 under the saver).
    public let pollStretch: Int
    /// The Mac is going to sleep or asleep: keepalives and polls stop.
    public let suspended: Bool
    /// The displays sleep: nothing can see ambient frames.
    public let screensAsleep: Bool
    /// The Mac runs on battery (raw input, for consumers such as KeepAwake).
    public let onBattery: Bool

    /// The policy for the resolved saver state and raw inputs; every derived value follows from them.
    ///
    /// - Parameters:
    ///   - saverReason: Why the saver is on, or nil when it is off.
    ///   - suspended: The Mac is going to sleep or asleep.
    ///   - screensAsleep: The displays sleep.
    ///   - onBattery: The Mac runs on battery.
    public init(saverReason: Reason? = nil, suspended: Bool = false, screensAsleep: Bool = false, onBattery: Bool = false) {
        let isSaver = saverReason != nil
        self.isSaver = isSaver
        reason = saverReason
        wakeAlignment = isSaver ? WakeLeeway.saverAlignment : WakeLeeway.defaultAlignment
        ambientMaxFPS = isSaver ? Self.saverFrameRate : nil
        webFrameRate = isSaver ? Self.saverFrameRate : nil
        pollStretch = isSaver ? Self.saverPollStretch : 1
        self.suspended = suspended
        self.screensAsleep = screensAsleep
        self.onBattery = onBattery
    }

    /// The saver off, awake, on AC power.
    public static let normal = EnergyPolicy()
}

/// The current ``EnergyPolicy`` and the code told when it changes. The composition root makes one,
/// updates it from its energy monitor (the one writer) and injects it into every consumer; there is
/// no shared instance.
///
/// Readers on any thread read ``policy`` (a short lock, no hop). Observers run on the writer's
/// thread right after a change, outside the lock, so an observer may read the source or update its
/// own locked state; one that needs the main actor hops there itself.
public final class EnergyPolicySource: Sendable {
    public typealias Observer = @Sendable (EnergyPolicy) -> Void

    private struct State {
        var policy: EnergyPolicy
        var observers: [UInt64: Observer] = [:]
        var nextID: UInt64 = 0
    }

    /// Short critical sections from any thread: synchronous reads on schedulers' insert paths,
    /// which an actor would turn into async hops (lock carve-out, CLAUDE.md).
    private let state: Mutex<State>

    /// A source that holds `policy` until ``update(_:)`` changes it.
    public init(_ policy: EnergyPolicy = .normal) {
        state = Mutex(State(policy: policy))
    }

    /// A new source fixed at ``EnergyPolicy/normal`` until someone updates it (a consumer's default
    /// when nothing injects the app's source: tests and window-less helpers).
    public static var normal: EnergyPolicySource { EnergyPolicySource() }

    /// The policy now.
    public var policy: EnergyPolicy { state.withLock { $0.policy } }

    /// Replaces the policy and tells every observer when it changed; an equal value tells nobody.
    public func update(_ policy: EnergyPolicy) {
        let observers: [Observer]? = state.withLock { state in
            guard state.policy != policy else { return nil }
            state.policy = policy
            return state.observers.sorted { $0.key < $1.key }.map(\.value)
        }
        for observer in observers ?? [] { observer(policy) }
    }

    /// Calls `observer` after each change until the returned observation is cancelled or released.
    public func observe(_ observer: @escaping Observer) -> EnergyPolicyObservation {
        let id = state.withLock { state in
            state.nextID &+= 1
            state.observers[state.nextID] = observer
            return state.nextID
        }
        return EnergyPolicyObservation { [weak self] in self?.removeObserver(id) }
    }

    /// Observers registered now (debug.energy and tests).
    public var observerCount: Int { state.withLock { $0.observers.count } }

    private func removeObserver(_ id: UInt64) {
        state.withLock { _ = $0.observers.removeValue(forKey: id) }
    }
}

/// One ``EnergyPolicySource/observe(_:)`` registration: cancelled by ``cancel()`` or on release.
public final class EnergyPolicyObservation: Sendable {
    private let onCancel: Mutex<(@Sendable () -> Void)?>

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = Mutex(onCancel)
    }

    deinit { cancel() }

    /// Stops the observer; later calls do nothing.
    public func cancel() {
        let remove = onCancel.withLock { slot in
            defer { slot = nil }
            return slot
        }
        remove?()
    }
}
