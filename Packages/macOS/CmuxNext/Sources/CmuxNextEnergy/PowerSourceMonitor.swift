import CmuxNextCompat
import CmuxNextWakeups
import Dispatch
import Foundation
import IOKit
import IOKit.ps
import notify

/// The power source, followed off the main thread: notify(3)'s power-source notification (and its
/// charge notification, only while on battery) on one utility queue, read there, and handed to the
/// main actor only when what Energy Saver decides from changes (``Edge``). A Mac without an
/// `IOPMPowerSource` registers nothing and reads nothing. Chrome follows the same IOKit service
/// (components/power_monitor/battery_state_sampler_mac.cc, `IOPMPowerSourceSamplingEventSource`)
/// and registers nothing on a desktop Mac; it takes the event on its UI thread, cmux takes it here.
///
/// All work runs on ``System/post``'s queue except ``start(_:)`` and ``stop()``, which only swap the
/// run under the state's lock; a run that ``stop()`` ended changes nothing when its queue work or its
/// main-actor delivery comes.
nonisolated final class PowerSourceMonitor: Sendable {
    /// What the main actor hears about: a reading in the same ``Edge`` as the last one it got is
    /// not sent. On battery above the low-battery threshold a charge step is not an edge (80% to
    /// 50% sends nothing); the source changing, crossing the threshold, and each step below it
    /// (which the low-battery card shows) are.
    nonisolated struct Edge: Equatable, Sendable {
        var onBattery: Bool
        var hasBattery: Bool
        /// The charge while on battery below the threshold, else nil.
        var lowPercent: Int?

        init(_ reading: PowerSourceReading) {
            onBattery = reading.onBattery
            hasBattery = reading.hasBattery
            if reading.onBattery, let percent = reading.batteryPercent,
               percent < EnergyPolicyResolver.lowBatteryThresholdPercent {
                lowPercent = percent
            } else {
                lowPercent = nil
            }
        }
    }

    /// notify(3)'s name for a battery charge change. IOPowerSources.h's `kIOPSNotifyPercentChange`
    /// is not imported into Swift from the macOS SDK, so its value is spelled here.
    static let percentChangeNotification = "com.apple.system.powersources.percent"

    /// The system calls the monitor makes; a test passes a fake Mac.
    nonisolated struct System: Sendable {
        /// The Mac has an `IOPMPowerSource` service (a Mac mini, Studio or Pro has none).
        var hasPowerSource: @Sendable () -> Bool
        /// The power source now, one snapshot.
        var read: @Sendable () -> PowerSourceReading
        /// Calls the handler on the monitor's queue after each post of the notify(3) name; the
        /// token, or nil when notifyd refuses.
        var register: @Sendable (_ name: String, _ handler: @escaping @Sendable () -> Void) -> Int32?
        /// Ends a registration.
        var cancel: @Sendable (_ token: Int32) -> Void
        /// Runs work on the monitor's queue.
        var post: @Sendable (_ work: @escaping @Sendable () -> Void) -> Void
        /// Runs work on the main actor, called from the monitor's queue.
        var toMain: @Sendable (_ work: @escaping @MainActor @Sendable () -> Void) -> Void

        /// IOKit and notify(3) on the app's one power-source queue; a reading reaches the main actor as one
        /// `visible` task on `mainWork` (it changes the energy policy and the low-battery card the person sees),
        /// so it waits behind the person's input like any posted task.
        static func live(mainWork: MainWorkScheduler) -> System {
            let queue = DispatchQueue.checked(label: "com.cmuxterm.next.energy.power-source", qos: .utility)
            let owner = mainWork.board.owner("Energy.powerSource")
            return System(hasPowerSource: { PowerSourceMonitor.hasPowerSourceService() },
                          read: { PowerSourceMonitor.read() },
                          register: { name, handler in
                              var token: Int32 = 0
                              // SAFETY: `name` is a NUL-terminated copy Swift keeps alive for the call, and
                              // notify writes one Int32 to the local `token` before it returns.
                              let status = unsafe notify_register_dispatch(name, &token, queue) { _ in handler() }
                              return status == UInt32(NOTIFY_STATUS_OK) ? token : nil
                          },
                          cancel: { token in _ = notify_cancel(token) },
                          post: { work in queue.async(execute: work) },
                          toMain: { work in mainWork.postFromAnyThread(.visible, owner: owner, work) })
        }
    }

    private nonisolated struct State {
        /// Counts runs: queue work of an earlier run sees a different number and does nothing.
        var run = 0
        /// The main-actor handler of the current run; nil when stopped.
        var deliver: (@MainActor @Sendable (PowerSourceReading) -> Void)?
        var sourceToken: Int32?
        var percentToken: Int32?
        /// The edge of the last reading sent to the main actor in this run.
        var heard: Edge?

        /// Ends the run and gives back its registrations.
        mutating func end() -> [Int32] {
            run += 1
            deliver = nil
            heard = nil
            defer { sourceToken = nil; percentToken = nil }
            return [sourceToken, percentToken].compactMap { $0 }
        }
    }

    private let system: System
    private let state = Mutex(State())

    init(system: System) {
        self.system = system
    }

    deinit {
        let tokens = state.withLock { $0.end() }
        tokens.forEach(system.cancel)
    }

    /// Starts following the power source: `deliver` gets the first reading, then each one in a new
    /// ``Edge``, on the main actor. A second call before ``stop()`` does nothing.
    func start(_ deliver: @escaping @MainActor @Sendable (PowerSourceReading) -> Void) {
        let run: Int? = state.withLock { state in
            guard state.deliver == nil else { return nil }
            state.run += 1
            state.deliver = deliver
            return state.run
        }
        guard let run else { return }
        system.post { [weak self] in self?.begin(run) }
    }

    /// Ends the registrations; nothing more reaches the handler. ``start(_:)`` may run again.
    func stop() {
        let tokens = state.withLock { $0.end() }
        guard !tokens.isEmpty else { return }
        let cancel = system.cancel
        system.post { tokens.forEach(cancel) }
    }

    /// The first reading of `run`, on the queue: a Mac without a battery stops here, registered for nothing.
    private func begin(_ run: Int) {
        guard isCurrent(run), system.hasPowerSource() else { return }
        let reading = system.read()
        guard reading.hasBattery else { return }
        let token = system.register(kIOPSNotifyPowerSource) { [weak self] in self?.changed(run) }
        guard keep(token, in: \.sourceToken, run: run) else { return }
        apply(reading, run: run)
    }

    private func changed(_ run: Int) {
        guard isCurrent(run) else { return }
        apply(system.read(), run: run)
    }

    /// Follows the charge only on battery, and sends `reading` when its edge is new.
    private func apply(_ reading: PowerSourceReading, run: Int) {
        let edge = Edge(reading)
        let next: (deliver: (@MainActor @Sendable (PowerSourceReading) -> Void)?, percentToken: Int32?)? = state.withLock { state in
            guard state.run == run, let deliver = state.deliver else { return nil }
            defer { state.heard = edge }
            return (state.heard == edge ? nil : deliver, state.percentToken)
        }
        guard let next else { return }
        if reading.onBattery, next.percentToken == nil {
            let token = system.register(Self.percentChangeNotification) { [weak self] in self?.changed(run) }
            guard keep(token, in: \.percentToken, run: run) else { return }
        } else if !reading.onBattery, let token = next.percentToken {
            state.withLock { if $0.run == run { $0.percentToken = nil } }
            system.cancel(token)
        }
        if let deliver = next.deliver {
            system.toMain { [weak self] in
                guard self?.isCurrent(run) == true else { return }
                deliver(reading)
            }
        }
    }

    /// Stores `token` in the run's `slot`; a run that ended meanwhile gets it cancelled. False when it did.
    private func keep(_ token: Int32?, in slot: WritableKeyPath<State, Int32?>, run: Int) -> Bool {
        let kept = state.withLock { state in
            guard state.run == run else { return false }
            state[keyPath: slot] = token
            return true
        }
        if !kept, let token { system.cancel(token) }
        return kept
    }

    private func isCurrent(_ run: Int) -> Bool {
        state.withLock { $0.run == run && $0.deliver != nil }
    }

    /// The Mac has an `IOPMPowerSource` service, the one a battery publishes (Chrome's check before it samples).
    static func hasPowerSourceService() -> Bool {
        // SAFETY: the class name is a NUL-terminated literal Swift keeps alive for the call; the
        // matching dictionary it returns is consumed by IOServiceGetMatchingService.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, unsafe IOServiceMatching("IOPMPowerSource"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    /// The power source now, from one IOKit snapshot (one IPC to powerd): whether the battery
    /// provides power (false on adapter power, a UPS counted as AC, and a Mac with no battery) and
    /// the internal battery.
    static func read() -> PowerSourceReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return PowerSourceReading() }
        let type = IOPSGetProvidingPowerSourceType(info).map { $0.takeUnretainedValue() as String }
        let battery = BatteryLevel(info: info)
        return PowerSourceReading(onBattery: type == kIOPMBatteryPowerKey, hasBattery: battery.hasBattery,
                                  batteryPercent: battery.percent)
    }
}
