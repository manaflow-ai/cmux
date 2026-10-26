public import CmuxNextSettings
public import CmuxNextWakeups
public import Darwin
public import Foundation

/// `debug.energy`: the Energy Saver state and what the app costs while idle
/// (plans/cmux-next/chrome-parity/p14-energy.md, task 007). The top-level keys are exactly:
///
/// - `policy`: the resolved ``EnergyPolicy`` (saver on, reason, wake alignment, frame caps, poll stretch).
/// - `inputs`: what the policy was resolved from: Low Power Mode, power source, battery, thermal state,
///   the `energy.saver` setting, "Turn Off for Now", sleep and screen sleep, and the reason given.
/// - `wake_queue`: the main thread's ``MainWakeUpQueue``: pending entries, its wakes (the ledger's
///   `MainWakeUpQueue`/`fire` record, one per wake) and its alignment grid.
/// - `ledger_top`: the 10 ``WakeupLedger`` owners that wake the app most, all reasons summed.
/// - `processes`: CPU energy and wakeups per process of the app tree, cumulative (diff two calls for
///   rates). Interrupt wakeups are what Chrome reports as idle wakeups
///   (base/process/process_metrics_apple.mm, `GetIdleWakeupsPerSecond` reads `ri_interrupt_wkups`);
///   package-idle wakeups are a subset and are reported apart, never summed.
/// - `cef`: whether Chromium applies the Energy Saver, and the pump's early passes.
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
    let processes: @Sendable () -> [ProcessEnergy]

    /// A report over these readers.
    ///
    /// - Parameters:
    ///   - state: Copies the energy services' state in one main-actor turn; nil once they are gone.
    ///   - ledger: The app's wakeup ledger (the wake queue records its wakes there).
    ///   - processes: Samples the app tree (``ProcessEnergy/sample(kind:pid:name:)``); called off the main actor.
    public init(state: @escaping @MainActor @Sendable () -> State?, ledger: WakeupLedger,
                processes: @escaping @Sendable () -> [ProcessEnergy]) {
        self.state = state
        self.ledger = ledger
        self.processes = processes
    }

    /// `debug.energy`.
    public var method: ControlMethod { .async("debug.energy") { [self] _ in await report() } }

    /// The report: `.null` once the services are gone.
    public func report() async -> JSONValue {
        guard let state = await state() else { return .null }
        let sampled = await Self.sample(ledger: ledger, processes: processes)
        return Self.render(state: state, ledger: sampled.ledger, processes: sampled.processes)
    }

    @concurrent
    private static func sample(ledger: WakeupLedger, processes: @Sendable () -> [ProcessEnergy]) async
        -> (ledger: [WakeupLedger.Entry], processes: [ProcessEnergy]) {
        (ledger.snapshot(), processes())
    }

    static func render(state: State, ledger: [WakeupLedger.Entry], processes: [ProcessEnergy]) -> JSONValue {
        let fire = ledger.first { $0.owner == MainWakeUpQueue.ledgerOwner && $0.reason == "fire" }
        return [
            "policy": state.policyJSON,
            "inputs": state.inputs.json(policy: state.policy),
            "wake_queue": state.wakeQueue.json(fire: fire, alignment: state.policy.wakeAlignment),
            "ledger_top": .array(LedgerOwner.top(ledger, count: Self.ledgerTopCount).map(\.json)),
            "processes": .array(processes.map(\.json)),
            "cef": state.cef.json,
        ]
    }

    static func ms(_ duration: Duration) -> JSONValue {
        let (seconds, attoseconds) = duration.components
        return .number(Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
    }
}

extension EnergyReport {
    /// Everything `debug.energy` reads on the main actor, copied in one turn.
    public struct State: Sendable, Equatable {
        public var policy: EnergyPolicy
        public var inputs: Inputs
        public var wakeQueue: WakeQueue
        public var cef: CEF

        public init(policy: EnergyPolicy, inputs: Inputs, wakeQueue: WakeQueue, cef: CEF) {
            self.policy = policy
            self.inputs = inputs
            self.wakeQueue = wakeQueue
            self.cef = cef
        }
    }

    /// The power inputs, the setting and the session override the policy was resolved from. Sleep,
    /// screen sleep and the reason come from the policy itself.
    public struct Inputs: Sendable, Equatable {
        public var lowPowerMode: Bool
        public var onBattery: Bool
        public var hasBattery: Bool
        /// nil on a Mac with no battery, and on AC power (the monitor reads the charge only on battery).
        public var batteryPercent: Int?
        public var thermal: ProcessInfo.ThermalState
        public var setting: EnergySaverMode
        /// "Turn Off Energy Saver for Now" holds.
        public var sessionOverride: Bool

        public init(lowPowerMode: Bool, onBattery: Bool, hasBattery: Bool, batteryPercent: Int?,
                    thermal: ProcessInfo.ThermalState, setting: EnergySaverMode, sessionOverride: Bool) {
            self.lowPowerMode = lowPowerMode
            self.onBattery = onBattery
            self.hasBattery = hasBattery
            self.batteryPercent = batteryPercent
            self.thermal = thermal
            self.setting = setting
            self.sessionOverride = sessionOverride
        }

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
    }

    /// The main wake queue now.
    public struct WakeQueue: Sendable, Equatable {
        /// Entries waiting to run.
        public var entries: Int

        public init(entries: Int) {
            self.entries = entries
        }

        /// `fire` is the queue's ledger record, one per wake of its timer; `alignment` is the grid flexible
        /// sub-second entries snap to (the policy's `wakeAlignment`).
        func json(fire: WakeupLedger.Entry?, alignment: Duration) -> JSONValue {
            [
                "entries": JSONValue(entries),
                "fires": JSONValue(Int(truncatingIfNeeded: fire?.count ?? 0)),
                "fires_per_second": .number(fire?.perSecond ?? 0),
                "alignment_ms": EnergyReport.ms(alignment),
            ]
        }
    }

    /// Chromium's side of Energy Saver.
    public struct CEF: Sendable, Equatable {
        public enum Saver: String, Sendable {
            case applied
            /// The app makes no call into the fork's Energy Saver API (p14-energy-030).
            case unsupported
        }

        public var saver: Saver
        /// Pump passes followed within 2 ms by a delayed request under 2 ms; nil while the pump does not
        /// count them (p14-energy-018).
        public var earlyPasses: Int?

        public init(saver: Saver, earlyPasses: Int?) {
            self.saver = saver
            self.earlyPasses = earlyPasses
        }

        var json: JSONValue {
            [
                "energy_saver": .string(saver.rawValue),
                "early_passes": earlyPasses.map { JSONValue($0) } ?? .null,
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
                "count": JSONValue(Int(truncatingIfNeeded: count)),
                "per_second": .number(perSecond),
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
            "low_power_mode": .bool(lowPowerMode),
            "on_battery": .bool(onBattery),
            "has_battery": .bool(hasBattery),
            "battery_percent": batteryPercent.map { EnergyReport.JSONValue($0) } ?? .null,
            "thermal": .string(Self.name(thermal)),
            "setting": .string(setting.rawValue),
            "session_override": .bool(sessionOverride),
            "suspended": .bool(policy.suspended),
            "screens_asleep": .bool(policy.screensAsleep),
            "reason": policy.reason.map { EnergyReport.JSONValue.string($0.rawValue) } ?? .null,
        ]
    }
}

extension EnergyReport.State {
    var policyJSON: EnergyReport.JSONValue {
        [
            "is_saver": .bool(policy.isSaver),
            "reason": policy.reason.map { EnergyReport.JSONValue.string($0.rawValue) } ?? .null,
            "wake_alignment_ms": EnergyReport.ms(policy.wakeAlignment),
            "ambient_max_fps": policy.ambientMaxFPS.map { EnergyReport.JSONValue($0) } ?? .null,
            "web_frame_rate": policy.webFrameRate.map { EnergyReport.JSONValue($0) } ?? .null,
            "poll_stretch": EnergyReport.JSONValue(policy.pollStretch),
        ]
    }
}

/// CPU energy and wakeups of one process of the app tree (`proc_pid_rusage`, `RUSAGE_INFO_V6`).
public struct ProcessEnergy: Sendable, Equatable {
    public var kind: String
    public var pid: pid_t
    public var name: String
    /// CPU energy since the process started (`ri_energy_nj`); work billed to the render server is not in it.
    public var energyNanojoules: UInt64
    /// Chrome's idle wakeups (`ri_interrupt_wkups`).
    public var interruptWakeups: UInt64
    /// Wakeups out of package idle (`ri_pkg_idle_wkups`), a subset of the interrupt wakeups.
    public var packageIdleWakeups: UInt64

    public init(kind: String, pid: pid_t, name: String, energyNanojoules: UInt64, interruptWakeups: UInt64,
                packageIdleWakeups: UInt64) {
        self.kind = kind
        self.pid = pid
        self.name = name
        self.energyNanojoules = energyNanojoules
        self.interruptWakeups = interruptWakeups
        self.packageIdleWakeups = packageIdleWakeups
    }

    /// Samples `pid`; nil when the process is gone or not ours. Blocking syscalls: call it off the main actor.
    public static func sample(kind: String, pid: pid_t, name: String) -> ProcessEnergy? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else { return nil }
        return ProcessEnergy(kind: kind, pid: pid, name: name, energyNanojoules: info.ri_energy_nj,
                             interruptWakeups: info.ri_interrupt_wkups, packageIdleWakeups: info.ri_pkg_idle_wkups)
    }

    var json: EnergyReport.JSONValue {
        [
            "kind": .string(kind), "pid": .number(Double(pid)), "name": .string(name),
            "energy_nj": EnergyReport.JSONValue(Int(truncatingIfNeeded: energyNanojoules)),
            "interrupt_wakeups": EnergyReport.JSONValue(Int(truncatingIfNeeded: interruptWakeups)),
            "pkg_idle_wakeups": EnergyReport.JSONValue(Int(truncatingIfNeeded: packageIdleWakeups)),
        ]
    }
}
