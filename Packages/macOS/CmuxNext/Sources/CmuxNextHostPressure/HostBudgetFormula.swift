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
