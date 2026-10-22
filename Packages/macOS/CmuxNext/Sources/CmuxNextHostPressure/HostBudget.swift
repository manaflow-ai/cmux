public import Foundation

/// The host CPU/RAM budget acpmux and cmux NEXT share (the host-budget
/// contract, cmuxterm-hq#2995): a formula derived from the machine, never a
/// hand-set cap. Its keys are the contract's; an override file may change any
/// of them (`HostBudgetOverride`).
public struct HostBudgetFormula: Equatable, Sendable {
    /// Over when the 1-minute load reaches `cores * load1PerCore`.
    public var load1PerCore = 1.0
    /// Which cores count: "performance" (hw.perflevel0.physicalcpu) or "all".
    public var cores = "performance"
    /// Over when the swap-out rate reaches this many MB a minute.
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
    public var swapGrowthMBPerMin: Double?

    enum CodingKeys: String, CodingKey {
        case load1PerCore = "load1_per_core"
        case cores
        case swapGrowthMBPerMin = "swap_growth_mb_per_min"
    }

    func applied(to formula: HostBudgetFormula) -> HostBudgetFormula {
        var formula = formula
        if let load1PerCore, load1PerCore > 0 { formula.load1PerCore = load1PerCore }
        if let cores { formula.cores = cores }
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
    /// then its `hosts[host]`.
    public func formula(host: String) -> HostBudgetFormula {
        let base = formula?.applied(to: HostBudgetFormula()) ?? HostBudgetFormula()
        let short = host.split(separator: ".").first.map(String.init) ?? host
        guard let layer = hosts?[host] ?? hosts?[short] else { return base }
        return layer.applied(to: base)
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
public enum HostMemoryPressure: String, Comparable, Sendable, Codable {
    case normal, warn, critical

    public init(sysctlLevel: Int32) {
        self = sysctlLevel >= 4 ? .critical : sysctlLevel >= 2 ? .warn : .normal
    }

    private var rank: Int { self == .normal ? 0 : self == .warn ? 1 : 2 }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// The contract's verdict, as `acpmux daemon status --json` reports it in
/// `host_pressure` (and `host-budget --json`): what the host is at against
/// its budget, and which parts are over.
public struct HostBudgetVerdict: Codable, Equatable, Sendable {
    public var host: String
    public var cores: Int
    public var load1: Double
    public var loadLimit: Double
    public var pressure: HostMemoryPressure
    public var swapMBPerMin: Double
    public var over: [String]
    public var ok: Bool

    enum CodingKeys: String, CodingKey {
        case host, cores, load1, pressure, over, ok
        case loadLimit = "load_limit"
        case swapMBPerMin = "swap_mb_per_min"
    }

    public init(host: String, cores: Int, load1: Double, loadLimit: Double, pressure: HostMemoryPressure,
                swapMBPerMin: Double, swapLimit: Double) {
        self.host = host
        self.cores = cores
        self.load1 = load1
        self.loadLimit = loadLimit
        self.pressure = pressure
        self.swapMBPerMin = swapMBPerMin
        var over: [String] = []
        if load1 >= loadLimit { over.append("cpu") }
        if pressure != .normal { over.append("memory") }
        if swapMBPerMin >= swapLimit { over.append("swap") }
        self.over = over
        ok = over.isEmpty
    }

    /// The same verdict with the newer memory pressure the dispatch source
    /// reported (the contract lets the app read it itself, for speed).
    public func with(pressure newer: HostMemoryPressure) -> Self {
        guard newer != pressure else { return self }
        var copy = self
        copy.pressure = newer
        copy.over = [over.contains("cpu") ? "cpu" : nil, newer != .normal ? "memory" : nil, over.contains("swap") ? "swap" : nil]
            .compactMap(\.self)
        copy.ok = copy.over.isEmpty
        return copy
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
