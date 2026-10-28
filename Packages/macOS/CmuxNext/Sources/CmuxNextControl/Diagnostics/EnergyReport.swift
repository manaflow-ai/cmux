public import CmuxNextSettings
public import CmuxNextWakeups
public import Foundation

/// `debug.energy`: the Energy Saver state and what the app costs while idle
/// (plans/cmux-next/chrome-parity/p14-energy.md, tasks 007 and 008). The top-level keys are exactly:
///
/// - `policy`: the resolved ``EnergyPolicy`` (saver on, reason, wake alignment, frame caps, poll stretch, and
///   `pageSaver`: pages spend less, under the saver or Low Power Mode while the feature is off).
/// - `inputs`: what the policy was resolved from: the `energySaver` feature, Low Power Mode, power source,
///   battery, thermal state, the `energy.saver` setting, "Turn Off for Now", sleep and screen sleep, the
///   reason given, and whether `debug.energy.simulate` lays inputs over the Mac's (`simulated`).
/// - `wake_queue`: the main thread's ``MainWakeUpQueue``: pending entries, its wakes (the ledger's
///   `MainWakeUpQueue`/`fire` record, one per wake), the wakes that ran more than one entry, and its
///   alignment grid.
/// - `ledger_top`: the 10 ``WakeupLedger`` owners that wake the app most, all reasons summed.
/// - `processes`: CPU energy and wakeups per process of the app tree from one ``ProcessUsage`` sample,
///   cumulative (diff two calls for rates). Interrupt wakeups are what Chrome reports as idle wakeups:
///   `GetIdleWakeupsPerSecond` (base/process/process_metrics_apple.mm) reads
///   `task_power_info.task_interrupt_wakeups` from `task_info(TASK_POWER_INFO)`, and `ri_interrupt_wkups`
///   is the same kernel counter read through `proc_pid_rusage` for other pids. Package-idle wakeups are
///   a subset and are reported apart, never summed.
/// - `cef`: whether Chromium applies the Energy Saver, and the pump's early passes.
/// - `idle`: the main process's interrupt wakeups per second over this launch's idle minutes, as a
///   histogram with fixed buckets and its p50/p95/p99 (``IdleEnergyStats``, task 008). Main process
///   only (`scope`); the helpers' counters are in `processes`, from the same ``ProcessUsage`` counter.
/// - `tabs`: each Chromium tab with the CPU, energy and wakeups of the renderers that serve it
///   (``ProcessUsage/perTab(_:renderers:)``, task 124), cumulative like `processes`. A tab renderer of
///   `processes` is a tab's when it hosts its main frame (the fork's `cmux_cef_browser_renderer_pid`) or
///   any of its frames (renderer client ids against the helper's `--renderer-client-id`). Same-site tabs
///   can share one renderer: each of them shows its whole usage, and the renderer's `tabs` name all of
///   them. In process only: with the Chromium Host on, the renderers are the host's children and no
///   tab lists one.
///
/// Top-level keys are snake_case (the spec's); the fields inside them are the camelCase names of the
/// values they report (`policy.isSaver` is ``EnergyPolicy/isSaver``), which is what
/// `scripts/cmux-next/idle-budget.py` (`saver_state`) reads.
///
/// One main-actor turn copies ``State``; the ledger read and the process sampling run on the
/// concurrent pool, never on the main actor (as `debug.wakeups` samples its processes). The App
/// registers ``method`` next to `debug.wakeups` with a ``State`` reader over its energy services.
public struct EnergyReport: Sendable {
    public typealias JSONValue = CmuxNextSettings.JSONValue

    /// The owners `ledger_top` lists.
    public static let ledgerTopCount = 10

    /// The main-actor part; nil once the services are gone.
    let state: @MainActor @Sendable () -> State?
    let ledger: WakeupLedger
    /// Samples the app tree; runs off the main actor.
    let processes: @Sendable () -> [ProcessSample]

    /// A report over these readers.
    ///
    /// - Parameters:
    ///   - state: Copies the energy services' state in one main-actor turn; nil once they are gone.
    ///   - ledger: The app's wakeup ledger (the wake queue records its wakes there).
    ///   - processes: Samples the app tree (``ProcessUsage/sample(_:)`` per process); called off the main actor.
    public init(state: @escaping @MainActor @Sendable () -> State?, ledger: WakeupLedger,
                processes: @escaping @Sendable () -> [ProcessSample]) {
        self.state = state
        self.ledger = ledger
        self.processes = processes
    }

    /// `debug.energy`.
    public var method: ControlMethod { .async("debug.energy") { [self] _ in await report() } }

    /// The report: `.null` once the services are gone.
    public func report() async -> JSONValue {
        await report(from: await state())
    }

    /// The report over `state`, copied in an earlier main-actor turn; the ledger and the processes are
    /// sampled now, off the main actor.
    func report(from state: State?) async -> JSONValue {
        guard let state else { return .null }
        let sampled = await Self.sample(ledger: ledger, processes: processes, tabs: state.tabs)
        return Self.render(state: state, ledger: sampled.ledger, processes: sampled.processes, tabs: sampled.tabs)
    }

    @concurrent
    private static func sample(ledger: WakeupLedger, processes: @Sendable () -> [ProcessSample],
                               tabs: [ProcessUsage.TabRenderers]) async
        -> (ledger: [WakeupLedger.Entry], processes: [ProcessSample], tabs: [ProcessUsage.TabUsage]) {
        let sampled = processes()
        return (ledger.snapshot(), sampled, tabUsage(tabs, processes: sampled))
    }

    static func render(state: State, ledger: [WakeupLedger.Entry], processes: [ProcessSample],
                       tabs: [ProcessUsage.TabUsage] = []) -> JSONValue {
        let fire = ledger.first { $0.owner == MainWakeUpQueue.ledgerOwner && $0.reason == "fire" }
        return [
            "policy": Self.policyJSON(state.policy),
            "inputs": state.inputs.json(policy: state.policy),
            "wake_queue": state.wakeQueue.json(fire: fire, alignment: state.policy.wakeAlignment),
            "ledger_top": .array(LedgerOwner.top(ledger, count: Self.ledgerTopCount).map(\.json)),
            "processes": .array(processes.map(\.json)),
            "cef": state.cef.json,
            "idle": state.idle.json,
            "tabs": .array(tabs.map(Self.tabJSON)),
        ]
    }

    static func ms(_ duration: Duration) -> JSONValue {
        let (seconds, attoseconds) = duration.components
        return .number(Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
    }

    static func integer(_ value: UInt64) -> JSONValue { JSONValue(Int(truncatingIfNeeded: value)) }
}

extension EnergyReport {
    /// Everything `debug.energy` reads on the main actor, copied in one turn.
    public struct State: Sendable, Equatable {
        public var policy: EnergyPolicy
        public var inputs: Inputs
        public var wakeQueue: WakeQueue
        public var cef: CEF
        /// This launch's idle wakeup histogram.
        public var idle: IdleEnergyStats
        /// Every Chromium tab's renderers, as the tabs report them (`tabs`).
        public var tabs: [ProcessUsage.TabRenderers]

        public init(policy: EnergyPolicy, inputs: Inputs, wakeQueue: WakeQueue, cef: CEF,
                    idle: IdleEnergyStats = IdleEnergyStats(), tabs: [ProcessUsage.TabRenderers] = []) {
            self.policy = policy
            self.inputs = inputs
            self.wakeQueue = wakeQueue
            self.cef = cef
            self.idle = idle
            self.tabs = tabs
        }
    }

    /// The feature, the power inputs, the setting and the session override the policy was resolved
    /// from. Sleep, screen sleep and the reason come from the policy itself.
    public struct Inputs: Sendable, Equatable {
        /// The default-off `energySaver` feature is on; off, the saver stays off whatever the rest says.
        public var featureEnabled: Bool
        public var lowPowerMode: Bool
        public var onBattery: Bool
        public var hasBattery: Bool
        /// nil on a Mac with no battery, and on AC power (the monitor reads the charge only on battery).
        public var batteryPercent: Int?
        public var thermal: ProcessInfo.ThermalState
        public var setting: EnergySaverMode
        /// "Turn Off Energy Saver for Now" holds.
        public var sessionOverride: Bool
        /// `debug.energy.simulate` lays inputs over the Mac's (Debug and bench builds only).
        public var simulated: Bool

        public init(featureEnabled: Bool, lowPowerMode: Bool, onBattery: Bool, hasBattery: Bool, batteryPercent: Int?,
                    thermal: ProcessInfo.ThermalState, setting: EnergySaverMode, sessionOverride: Bool, simulated: Bool = false) {
            self.featureEnabled = featureEnabled
            self.lowPowerMode = lowPowerMode
            self.onBattery = onBattery
            self.hasBattery = hasBattery
            self.batteryPercent = batteryPercent
            self.thermal = thermal
            self.setting = setting
            self.sessionOverride = sessionOverride
            self.simulated = simulated
        }

        /// The states `thermal` reports, by name.
        static let thermalStates: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]

        /// `nominal`, `fair`, `serious` or `critical`.
        static func name(_ thermal: ProcessInfo.ThermalState) -> String {
            switch thermal {
            case .nominal: "nominal"
            case .fair: "fair"
            case .serious: "serious"
            case .critical: "critical"
            @unknown default: "unknown(\(thermal.rawValue))"
            }
        }

        /// The thermal state `name` reports (`nominal`, `fair`, `serious` or `critical`); nil for any other text.
        public static func thermal(named name: String) -> ProcessInfo.ThermalState? {
            thermalStates.first { Self.name($0) == name }
        }
    }

    /// The main wake queue now.
    public struct WakeQueue: Sendable, Equatable {
        /// Entries waiting to run.
        public var entries: Int
        /// Wakes that ran more than one entry (``MainWakeUpQueue/coalescedFires``).
        public var coalescedFires: UInt64

        public init(entries: Int, coalescedFires: UInt64) {
            self.entries = entries
            self.coalescedFires = coalescedFires
        }

        /// `fire` is the queue's ledger record, one per wake of its timer; `alignment` is the grid flexible
        /// sub-second entries snap to (the policy's `wakeAlignment`).
        func json(fire: WakeupLedger.Entry?, alignment: Duration) -> JSONValue {
            [
                "entries": JSONValue(entries),
                "fires": EnergyReport.integer(fire?.count ?? 0),
                "firesPerSecond": .number(fire?.perSecond ?? 0),
                "coalescedFires": EnergyReport.integer(coalescedFires),
                "alignmentMs": EnergyReport.ms(alignment),
            ]
        }
    }

    /// One process of the app tree: its kind (`app`, `cef-renderer`, `daemon`, ...) and one sample.
    public struct ProcessSample: Sendable, Equatable {
        public var kind: String
        public var usage: ProcessUsage
        /// A tab renderer's `--renderer-client-id` (the App's `ChromiumHelperProcess` classification);
        /// nil for every other process, extension renderers included. `tabs` attributes only these.
        public var rendererClientID: Int32?

        public init(kind: String, usage: ProcessUsage, rendererClientID: Int32? = nil) {
            self.kind = kind
            self.usage = usage
            self.rendererClientID = rendererClientID
        }

        var json: JSONValue {
            [
                "kind": .string(kind), "pid": JSONValue(Int(truncatingIfNeeded: usage.pid)), "name": .string(usage.name),
                "energyNj": EnergyReport.integer(usage.energyNanojoules),
                "interruptWakeups": EnergyReport.integer(usage.interruptWakeups),
                "packageIdleWakeups": EnergyReport.integer(usage.packageIdleWakeups),
            ]
        }
    }

    /// One ledger owner, every reason summed.
    struct LedgerOwner: Sendable, Equatable {
        var owner: String
        var count: UInt64
        var perSecond: Double
        /// Reasons, busiest first.
        var reasons: [String]

        var json: JSONValue {
            [
                "owner": .string(owner),
                "count": EnergyReport.integer(count),
                "perSecond": .number(perSecond),
                "reasons": .array(reasons.map(JSONValue.string)),
            ]
        }

        /// The `count` busiest owners. `entries` come busiest first (``WakeupLedger/snapshot()``), so each
        /// owner's reasons keep that order.
        static func top(_ entries: [WakeupLedger.Entry], count: Int) -> [LedgerOwner] {
            var owners: [String: LedgerOwner] = [:]
            for entry in entries {
                owners[entry.owner, default: LedgerOwner(owner: entry.owner, count: 0, perSecond: 0, reasons: [])]
                    .add(entry)
            }
            let sorted = owners.values.sorted { ($0.perSecond, $0.count, $1.owner) > ($1.perSecond, $1.count, $0.owner) }
            return Array(sorted.prefix(count))
        }

        private mutating func add(_ entry: WakeupLedger.Entry) {
            count &+= entry.count
            perSecond += entry.perSecond
            reasons.append(entry.reason)
        }
    }
}

extension EnergyReport.Inputs {
    /// With the sleep inputs and the reason of the policy these inputs resolved to.
    func json(policy: EnergyPolicy) -> EnergyReport.JSONValue {
        [
            "featureEnabled": .bool(featureEnabled),
            "lowPowerMode": .bool(lowPowerMode),
            "onBattery": .bool(onBattery),
            "hasBattery": .bool(hasBattery),
            "batteryPercent": batteryPercent.map { EnergyReport.JSONValue($0) } ?? .null,
            "thermal": .string(Self.name(thermal)),
            "setting": .string(setting.rawValue),
            "sessionOverride": .bool(sessionOverride),
            "suspended": .bool(policy.suspended),
            "screensAsleep": .bool(policy.screensAsleep),
            "reason": policy.reason.map { EnergyReport.JSONValue.string($0.rawValue) } ?? .null,
            "simulated": .bool(simulated),
        ]
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension EnergyReport {
    /// The simulate method's name.
    public static let simulateMethodName = "debug.energy.simulate"
    /// Its inputs, by wire name.
    static let simulatedInputNames: Set<String> = ["on_battery", "percent", "thermal", "low_power", "suspended"]

    /// `debug.energy.simulate {on_battery?, percent?, thermal?, low_power?, suspended?}` (Debug
    /// and bench builds only): `apply` lays these inputs over the Mac's in the energy monitor, so the policy
    /// resolves as on a Mac in that state; inputs not given follow the Mac. `low_power` and `thermal` go
    /// through the Mac's own seams (the Low Power Mode and thermal overrides), so every reader sees them.
    /// Each call replaces the previous simulation; `{clear: true}` hands `apply` nil, which restores the
    /// Mac's inputs and the overrides held before. A simulated power source never ends "Turn Off Energy
    /// Saver for Now". Answers ``report()`` for the state right after the change. Fleet Macs have no
    /// battery: the energy test phase checks the `auto` saver's `battery` reason with
    /// `{on_battery: true, percent: 15}` (scripts/cmux-next/energy-test-phase.py, D7 auto).
    ///
    /// A mutation, so it runs on the `mainActor` lane in the `automation` work class, behind the person's
    /// input: one main-actor turn applies the simulation and copies ``State``, and the follow-up samples
    /// the rest off the main actor. The answer is the state that turn made, whatever runs after it.
    ///
    /// - Parameter apply: Sets or clears the energy monitor's simulation, synchronously.
    public func simulateMethod(applying apply: @escaping @MainActor @Sendable (EnergySimulation?) -> Void) -> ControlMethod {
        .mainActor(Self.simulateMethodName) { [self] call in
            let simulation = try Self.simulation(call.params)
            apply(simulation)
            let applied = state()
            return .followUp { [self] in await report(from: applied) }
        }
    }

    /// The simulation `params` ask for; nil for `{clear: true}`. Anything else is `invalid_params`.
    static func simulation(_ params: [String: JSONValue]) throws(ControlError) -> EnergySimulation? {
        let name = simulateMethodName
        if let clear = params["clear"] {
            guard clear.boolValue == true, params.count == 1 else {
                throw ControlError.invalidParams("\(name): clear takes true and no other input")
            }
            return nil
        }
        if let unknown = params.keys.sorted().first(where: { !simulatedInputNames.contains($0) }) {
            throw ControlError.invalidParams("\(name): unknown input \(unknown); give on_battery, percent, thermal, low_power, suspended or clear")
        }
        guard !params.isEmpty else {
            throw ControlError.invalidParams("\(name): give on_battery, percent, thermal, low_power or suspended, or clear: true")
        }
        var percent: Int?
        if let value = params["percent"] {
            guard let number = value.intValue, (0...100).contains(number) else {
                throw ControlError.invalidParams("\(name): percent must be a whole number from 0 to 100")
            }
            percent = number
        }
        var thermal: ProcessInfo.ThermalState?
        if let value = params["thermal"] {
            guard let state = value.stringValue.flatMap(Inputs.thermal(named:)) else {
                throw ControlError.invalidParams("\(name): thermal must be nominal, fair, serious or critical")
            }
            thermal = state
        }
        let onBattery = try flag(params, "on_battery")
        let lowPowerMode = try flag(params, "low_power")
        let suspended = try flag(params, "suspended")
        return EnergySimulation(onBattery: onBattery, batteryPercent: percent, thermal: thermal,
                                lowPowerMode: lowPowerMode, suspended: suspended)
    }

    private static func flag(_ params: [String: JSONValue], _ key: String) throws(ControlError) -> Bool? {
        guard let value = params[key] else { return nil }
        guard let flag = value.boolValue else {
            throw ControlError.invalidParams("\(simulateMethodName): \(key) must be true or false")
        }
        return flag
    }
}
#endif
