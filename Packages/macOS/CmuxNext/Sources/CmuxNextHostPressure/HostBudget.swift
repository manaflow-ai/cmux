public import Foundation

/// The host CPU/RAM budget acpmux and cmux NEXT share (the host-budget
/// contract, cmuxterm-hq#2995): a formula derived from the machine, never a
/// hand-set cap. Its keys are the contract's; an override file may change any
/// of them (`HostBudgetOverride`).
public struct HostBudgetFormula: Equatable, Sendable {
    /// Over when the 1-minute load reaches `cores * load1PerCore`.
    public var load1PerCore = 1.0
    /// Which cores count: "performance" (hw.perflevel0.physicalcpu, else the
    /// physical cores) or "logical" (every CPU).
    public var cores = "performance"
    /// The highest memory pressure within budget: "normal" or "warn".
    public var pressure = "normal"
    /// Over when available RAM (kern.memorystatus_level) is under this fraction.
    public var minAvailableRAMFraction = 0.10
    /// Over when the swap-out rate is over this many MB a minute.
    public var swapGrowthMBPerMin = 64.0

    public init() {}

    /// The load the host admits: the core count times `load1PerCore`.
    public func loadLimit(cores count: Int) -> Double { Double(max(1, count)) * load1PerCore }
}

/// One override layer (`formula`, then `hosts[<host>]`) of the host-budget
/// file; absent keys keep what is below them.
public struct HostBudgetOverride: Decodable, Equatable, Sendable {
    public var load1PerCore: Double?
    public var cores: String?
    public var pressure: String?
    public var minAvailableRAMFraction: Double?
    public var swapGrowthMBPerMin: Double?

    enum CodingKeys: String, CodingKey {
        case load1PerCore = "load1_per_core"
        case cores, pressure
        case minAvailableRAMFraction = "min_available_ram_fraction"
        case swapGrowthMBPerMin = "swap_growth_mb_per_min"
    }

    /// acpmux's rules: positive numbers, a fraction in [0, 1] (0 turns the RAM
    /// reason off), known words only.
    func applied(to formula: HostBudgetFormula) -> HostBudgetFormula {
        var formula = formula
        if let load1PerCore, load1PerCore > 0 { formula.load1PerCore = load1PerCore }
        if let cores, ["performance", "logical"].contains(cores) { formula.cores = cores }
        if let pressure, ["normal", "warn"].contains(pressure) { formula.pressure = pressure }
        if let minAvailableRAMFraction, (0 ... 1).contains(minAvailableRAMFraction) {
            formula.minAvailableRAMFraction = minAvailableRAMFraction
        }
        if let swapGrowthMBPerMin, swapGrowthMBPerMin > 0 { formula.swapGrowthMBPerMin = swapGrowthMBPerMin }
        return formula
    }
}

/// The optional host-budget file: `$ACPMUX_HOST_BUDGET`, else
/// `~/.config/cmux/host-budget.json` (the contract's order).
public struct HostBudgetFile: Decodable, Equatable, Sendable {
    public var formula: HostBudgetOverride?
    public var hosts: [String: HostBudgetOverride]?

    /// The formula for `host`: the built-in defaults, the file's `formula`,
    /// then its `hosts` entry for the host's short name (`shortName(_:)`).
    public func formula(host: String) -> HostBudgetFormula {
        let base = formula?.applied(to: HostBudgetFormula()) ?? HostBudgetFormula()
        guard let layer = hosts?[Self.shortName(host)] else { return base }
        return layer.applied(to: base)
    }

    /// A host's name as acpmux keys it (host_pressure.rs `host_name`): before
    /// the first dot, trimmed, lowercased; "localhost" when empty.
    public static func shortName(_ host: String) -> String {
        let short = (host.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        return short.isEmpty ? "localhost" : short
    }

    /// The file's path, if one is configured.
    public static func path(environment: [String: String], home: URL) -> URL {
        if let explicit = environment["ACPMUX_HOST_BUDGET"], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        return home.appending(path: ".config/cmux/host-budget.json")
    }

    /// The formula from the configured file, or the defaults when there is
    /// none or it does not parse (a bad file never turns the warning off).
    public static func loadFormula(host: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> HostBudgetFormula {
        let url = path(environment: environment, home: home)
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(Self.self, from: data) else {
            return HostBudgetFormula()
        }
        return file.formula(host: host)
    }
}

/// The host's memory pressure as the budget reads it (macOS
/// kern.memorystatus_vm_pressure_level 1, 2, 4; the dispatch source's events).
/// acpmux reports `unknown` when it cannot read the level; it counts as normal.
public enum HostMemoryPressure: String, Comparable, Sendable, Codable {
    case normal, warn, critical, unknown

    public init(sysctlLevel: Int32) {
        self = sysctlLevel >= 4 ? .critical : sysctlLevel >= 2 ? .warn : .normal
    }

    private var rank: Int { self == .critical ? 2 : self == .warn ? 1 : 0 }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// Over a budget whose formula allows up to `allowed` ("normal" or "warn"):
    /// critical always is.
    public func isOver(allowing allowed: String) -> Bool {
        rank > (allowed == "warn" ? 1 : 0)
    }
}

/// The contract's verdict, as acpmux reports it in `host_pressure` (in
/// `_acpmux/status` and `acpmux daemon status --json`, cmux-tui
/// `host_pressure.rs`): what the host is at against its budget and why it is
/// over, one phrase per reason, in acpmux's words.
public struct HostBudgetVerdict: Codable, Equatable, Sendable {
    public var host: String
    public var cores: Int
    /// "performance", "physical" or "logical": which cores `cores` counts.
    public var coresKind: String?
    /// nil when the host could not read it.
    public var load1: Double?
    public var loadLimit: Double
    public var pressure: HostMemoryPressure
    /// nil until two samples.
    public var swapMBPerMin: Double?
    /// nil when the host could not read it.
    public var availableRAMFraction: Double?
    public var over: [String]
    public var ok: Bool
    /// The formula's allowance this verdict was judged with (only the key
    /// `with(pressure:)` needs).
    public var formula: Allowance?
    /// What acpmux knows and the app does not (absent in a local verdict).
    public var localTurns: Int?
    public var backgroundProcesses: Int?
    public var top: [HostBudgetSession]?

    enum CodingKeys: String, CodingKey {
        case host, cores, load1, pressure, over, ok, top, formula
        case loadLimit = "load_limit"
        case coresKind = "cores_kind"
        case availableRAMFraction = "available_ram_fraction"
        case swapMBPerMin = "swap_mb_per_min"
        case localTurns = "local_turns"
        case backgroundProcesses = "background_processes"
    }

    /// `formula.pressure` of a verdict: the highest memory pressure within budget.
    public struct Allowance: Codable, Equatable, Sendable {
        public var pressure: String?
    }

    /// A verdict from this Mac's own numbers with acpmux's reasons and tests
    /// (cmux-tui host_pressure.rs `evaluate`): load at or over its limit, memory
    /// pressure over the formula's allowance, available RAM under its fraction,
    /// swap growing faster than its limit.
    public init(host: String, cores: Int, coresKind: String = "performance", load1: Double, pressure: HostMemoryPressure,
                availableRAMFraction: Double?, swapMBPerMin: Double?, formula: HostBudgetFormula = HostBudgetFormula()) {
        self.host = host
        self.cores = cores
        self.coresKind = coresKind
        self.load1 = load1
        loadLimit = formula.loadLimit(cores: cores)
        self.pressure = pressure
        self.availableRAMFraction = availableRAMFraction
        self.swapMBPerMin = swapMBPerMin
        self.formula = Allowance(pressure: formula.pressure)
        var over: [String] = []
        if load1 >= loadLimit {
            let kind = coresKind == "performance" ? "P-cores" : "cores"
            over.append(String(format: "load1 %.1f >= %g", load1, loadLimit) + " (\(cores) \(kind))")
        }
        if pressure.isOver(allowing: formula.pressure) { over.append(Self.memoryReason(pressure)) }
        if let availableRAMFraction, availableRAMFraction < formula.minAvailableRAMFraction {
            over.append(String(format: "available RAM %.0f%% < %.0f%%", availableRAMFraction * 100, formula.minAvailableRAMFraction * 100))
        }
        if let swapMBPerMin, swapMBPerMin > formula.swapGrowthMBPerMin { over.append(String(format: "swap +%.0f MB/min", swapMBPerMin)) }
        self.over = over
        ok = over.isEmpty
    }

    private static let memoryPrefix = "memory pressure "
    private static func memoryReason(_ pressure: HostMemoryPressure) -> String { memoryPrefix + pressure.rawValue }

    /// The same verdict with the newer memory pressure the dispatch source
    /// reported (the contract lets the app read it itself, for speed).
    public func with(pressure newer: HostMemoryPressure) -> Self {
        guard newer != pressure else { return self }
        var copy = self
        copy.pressure = newer
        copy.over.removeAll { $0.hasPrefix(Self.memoryPrefix) }
        if newer.isOver(allowing: formula?.pressure ?? "normal") { copy.over.append(Self.memoryReason(newer)) }
        copy.ok = copy.over.isEmpty
        return copy
    }
}

/// One of acpmux's sessions in `host_pressure.top` (most background processes first).
public struct HostBudgetSession: Codable, Equatable, Sendable {
    public var sessionId: String
    public var name: String
    public var turns: Int
    public var processes: Int

    enum CodingKeys: String, CodingKey {
        case name, turns, processes
        case sessionId = "session_id"
    }
}

extension HostBudgetVerdict {
    private struct DaemonStatus: Decodable {
        var hostPressure: HostBudgetVerdict?
        enum CodingKeys: String, CodingKey { case hostPressure = "host_pressure" }
    }

    /// `host_pressure` from `acpmux daemon status --json`; nil when this
    /// acpmux does not report one (older daemons) or the output is not JSON.
    public static func fromDaemonStatus(_ data: Data) -> Self? {
        (try? JSONDecoder().decode(DaemonStatus.self, from: data))?.hostPressure
    }
}
