import Foundation
@testable import CmuxNextHostPressure
import Testing

/// The warning and the banner come from the shared host budget (12 performance
/// cores here, so a load limit of 12) and do not flicker.
struct HostPressureTrackerTests {
    private func verdict(load: Double = 2, pressure: HostMemoryPressure = .normal, ram: Double = 0.5, swap: Double = 0,
                         formula: HostBudgetFormula = HostBudgetFormula()) -> HostBudgetVerdict {
        HostBudgetVerdict(host: "gray", cores: 12, load1: load, pressure: pressure, availableRAMFraction: ram, swapMBPerMin: swap,
                          formula: formula)
    }

    @Test func aBusyButFineMacShowsNothing() {
        var tracker = HostPressureTracker()
        #expect(tracker.feed(verdict(load: 8.9)) == nil)
        #expect(tracker.level == .normal)
    }

    @Test func theWarningStartsBelowTheBudget() {
        var tracker = HostPressureTracker()
        #expect(tracker.feed(verdict(load: 9)) == .warning)
        #expect(verdict(load: 9).ok)
    }

    @Test(arguments: [
        (12.0, HostMemoryPressure.normal, 0.5, 0.0, HostPressureLevel.warning),
        (2, .warn, 0.5, 0, .warning),
        (2, .normal, 0.5, 65, .warning),
        (2, .normal, 0.5, 64, .normal),
        (2, .normal, 0.04, 0, .warning),
        (2, .normal, 0.10, 0, .normal),
        (13, .normal, 0.04, 0, .critical),
        (2, .critical, 0.5, 0, .critical),
        (146, .warn, 0.5, 0, .critical),
        (2, .warn, 0.5, 200, .critical),
        (146, .normal, 0.5, 0, .warning),
    ])
    func eachPartOfTheBudget(load: Double, pressure: HostMemoryPressure, ram: Double, swap: Double, level: HostPressureLevel) {
        #expect(HostPressureTracker.level(for: verdict(load: load, pressure: pressure, ram: ram, swap: swap), holding: .normal) == level)
    }

    /// acpmux's phrases, in its order, for each part of the budget.
    @Test func theLocalReasonsAreAcpmuxs() {
        #expect(verdict(load: 13, pressure: .warn, ram: 0.04, swap: 70).over == [
            "load1 13.0 >= 12 (12 P-cores)", "memory pressure warn", "available RAM 4% < 10%", "swap +70 MB/min",
        ])
    }

    /// A formula that allows warn pressure counts only critical, sampled or from an event.
    @Test func anAllowedWarnIsWithinBudget() {
        var formula = HostBudgetFormula()
        formula.pressure = "warn"
        let busy = verdict(load: 13, formula: formula)
        #expect(verdict(pressure: .warn, formula: formula).ok)
        #expect(busy.with(pressure: .warn).over.count == 1)
        #expect(HostPressureTracker.level(for: busy.with(pressure: .warn), holding: .normal) == .warning)
        #expect(HostPressureTracker.level(for: busy.with(pressure: .critical), holding: .normal) == .critical)
    }

    @Test func aRaisedLevelFallsOnlyAfterCalmSamples() {
        var tracker = HostPressureTracker(calmSamples: 2)
        #expect(tracker.feed(verdict(pressure: .critical)) == .critical)
        #expect(tracker.feed(verdict()) == nil)
        #expect(tracker.level == .critical)
        #expect(tracker.feed(verdict()) == .normal)
    }

    @Test func aPressedSampleResetsTheCalmStreak() {
        var tracker = HostPressureTracker(calmSamples: 2)
        _ = tracker.feed(verdict(pressure: .warn))
        #expect(tracker.feed(verdict()) == nil)
        #expect(tracker.feed(verdict(pressure: .warn)) == nil)
        #expect(tracker.feed(verdict()) == nil)
        #expect(tracker.feed(verdict()) == .normal)
    }

    @Test func aLoadWarningHoldsThroughTheDeadband() {
        var tracker = HostPressureTracker(calmSamples: 1)
        #expect(tracker.feed(verdict(load: 9)) == .warning)
        #expect(tracker.feed(verdict(load: 8)) == nil)
        #expect(tracker.level == .warning)
        #expect(tracker.feed(verdict(load: 7.7)) == .normal)
    }

    @Test func criticalStepsDownThroughWarning() {
        var tracker = HostPressureTracker(calmSamples: 1)
        _ = tracker.feed(verdict(load: 20, pressure: .warn))
        #expect(tracker.level == .critical)
        #expect(tracker.feed(verdict(load: 20)) == .warning)
        #expect(tracker.feed(verdict()) == .normal)
    }

    @Test func theDispatchSourcesPressureReplacesTheSampledOne() {
        let sampled = verdict(load: 13, swap: 70)
        #expect(sampled.formula?.pressure == "normal")
        #expect(sampled.over == ["load1 13.0 >= 12 (12 P-cores)", "swap +70 MB/min"])
        let newer = sampled.with(pressure: .warn)
        #expect(newer.over == ["load1 13.0 >= 12 (12 P-cores)", "swap +70 MB/min", "memory pressure warn"])
        #expect(newer.with(pressure: .critical).over.last == "memory pressure critical")
        #expect(newer.with(pressure: .normal).over == sampled.over)
        #expect(!newer.ok)
        #expect(verdict().with(pressure: .warn).with(pressure: .normal).ok)
    }
}

/// The formula is derived from the host and an optional override file, in the contract's order.
struct HostBudgetFormulaTests {
    @Test func theDefaultsAreTheContracts() {
        let formula = HostBudgetFormula()
        #expect(formula.loadLimit(cores: 12) == 12)
        #expect(formula.cores == "performance")
        #expect(formula.swapGrowthMBPerMin == 64)
        #expect(formula.pressure == "normal")
        #expect(formula.minAvailableRAMFraction == 0.10)
    }

    @Test func aHostOverrideBeatsTheFilesFormula() throws {
        let json = #"{"enforce": false, "formula": {"load1_per_core": 1.5, "sample_seconds": 3},"#
            + #" "hosts": {"cosmic-gray": {"swap_growth_mb_per_min": 128}}}"#
        let file = try JSONDecoder().decode(HostBudgetFile.self, from: Data(json.utf8))
        let gray = file.formula(host: "cosmic-gray.local")
        #expect(gray.load1PerCore == 1.5)
        #expect(gray.swapGrowthMBPerMin == 128)
        #expect(file.formula(host: "air-blue").swapGrowthMBPerMin == 64)
    }

    /// acpmux keys `hosts` by the lowercased short name, and 0 turns the RAM reason off.
    @Test func aMixedCaseHostGetsItsOverride() throws {
        let json = #"{"formula": {"min_available_ram_fraction": 0.2},"#
            + #" "hosts": {"cosmic-gray": {"load1_per_core": 2, "min_available_ram_fraction": 0}}}"#
        let file = try JSONDecoder().decode(HostBudgetFile.self, from: Data(json.utf8))
        let gray = file.formula(host: " Cosmic-Gray.local")
        #expect(HostBudgetFile.shortName(" Cosmic-Gray.local") == "cosmic-gray")
        #expect(gray.loadLimit(cores: 12) == 24)
        #expect(gray.minAvailableRAMFraction == 0)
        let verdict = HostBudgetVerdict(host: "cosmic-gray", cores: 12, load1: 25, pressure: .normal, availableRAMFraction: 0.04,
                                        swapMBPerMin: 0, formula: gray)
        #expect(verdict.over == ["load1 25.0 >= 24 (12 P-cores)"])
        #expect(HostPressureTracker.level(for: verdict, holding: .normal) == .warning)
        #expect(HostBudgetFile.shortName("") == "localhost")
    }

    @Test func aLogicalCoreBudgetSaysCores() {
        let verdict = HostBudgetVerdict(host: "x", cores: 15, coresKind: "logical", load1: 15, pressure: .normal,
                                        availableRAMFraction: nil, swapMBPerMin: nil)
        #expect(verdict.over == ["load1 15.0 >= 15 (15 cores)"])
    }

    @Test func theOverrideKeepsAcpmuxsRules() throws {
        let json = #"{"formula": {"pressure": "warn", "min_available_ram_fraction": 0.2, "cores": "logical"},"#
            + #" "hosts": {"bad": {"pressure": "critical", "min_available_ram_fraction": 2, "cores": "all"}}}"#
        let file = try JSONDecoder().decode(HostBudgetFile.self, from: Data(json.utf8))
        let formula = file.formula(host: "gray")
        #expect(formula.pressure == "warn")
        #expect(formula.minAvailableRAMFraction == 0.2)
        #expect(formula.cores == "logical")
        #expect(file.formula(host: "bad") == formula)
    }

    @Test func theEnvironmentPathComesFirst() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(HostBudgetFile.path(environment: ["ACPMUX_HOST_BUDGET": "/etc/budget.json"], home: home).path == "/etc/budget.json")
        #expect(HostBudgetFile.path(environment: [:], home: home).path == "/Users/someone/.config/cmux/host-budget.json")
    }

    @Test func aMissingFileKeepsTheDefaults() {
        let formula = HostBudgetFile.loadFormula(host: "x", environment: ["ACPMUX_HOST_BUDGET": "/nonexistent/budget.json"])
        #expect(formula == HostBudgetFormula())
    }

    /// acpmux's `host_pressure` as cmux-tui host_pressure.rs writes it.
    @Test func acpmuxsVerdictDecodes() throws {
        let json = #"{"host":"gray","cores":12,"cores_kind":"performance","load1":146.2,"load_limit":12,"pressure":"warn","#
            + #""available_ram_fraction":0.04,"swap_mb_per_min":90,"over":["load1 146.2 >= 12 (12 P-cores)","memory pressure warn","#
            + #""available RAM 4% < 10%","swap +90 MB/min"],"ok":false,"warning":"host-budget: gray over its CPU/RAM budget: ...","#
            + #""enforce":false,"local_turns":39,"background_processes":1298,"#
            + #""top":[{"session_id":"s1","name":"app-efficiency","turns":3,"processes":410}]}"#
        let verdict = try JSONDecoder().decode(HostBudgetVerdict.self, from: Data(json.utf8))
        #expect(verdict.loadLimit == 12)
        #expect(verdict.pressure == .warn)
        #expect(verdict.localTurns == 39)
        #expect(verdict.top?.first?.name == "app-efficiency")
        #expect(verdict.availableRAMFraction == 0.04)
        #expect(HostPressureTracker.level(for: verdict, holding: .normal) == .critical)
    }

    /// acpmux judged with `pressure: warn` allowed: a warn event adds no reason.
    @Test func acpmuxsAllowanceDecodes() throws {
        let json = #"{"host":"gray","cores":12,"load1":13,"load_limit":12,"pressure":"normal","swap_mb_per_min":0,"#
            + #""over":["load1 13.0 >= 12 (12 P-cores)"],"ok":false,"formula":{"load1_per_core":1,"pressure":"warn"}}"#
        let verdict = try JSONDecoder().decode(HostBudgetVerdict.self, from: Data(json.utf8))
        #expect(verdict.with(pressure: .warn).over.count == 1)
        #expect(HostPressureTracker.level(for: verdict.with(pressure: .warn), holding: .normal) == .warning)
    }

    /// Before its second sample acpmux has no swap rate, and it may not read the load or pressure.
    @Test func acpmuxsUnreadNumbersDecode() throws {
        let json = #"{"host":"gray","cores":12,"load1":null,"load_limit":12,"pressure":"unknown","#
            + #""swap_mb_per_min":null,"over":[],"ok":true}"#
        let verdict = try JSONDecoder().decode(HostBudgetVerdict.self, from: Data(json.utf8))
        #expect(verdict.load1 == nil)
        #expect(verdict.swapMBPerMin == nil)
        #expect(!verdict.pressure.isOver(allowing: "normal"))
        #expect(HostPressureTracker.level(for: verdict, holding: .normal) == .normal)
    }

    @Test func theVerdictComesFromDaemonStatus() {
        let status = #"{"build":"x","host_pressure":{"host":"gray","cores":12,"load1":3,"load_limit":12,"pressure":"normal","#
            + #""swap_mb_per_min":0,"over":[],"ok":true}}"#
        #expect(HostBudgetVerdict.fromDaemonStatus(Data(status.utf8))?.cores == 12)
        #expect(HostBudgetVerdict.fromDaemonStatus(Data(#"{"build":"x"}"#.utf8)) == nil)
        #expect(HostBudgetVerdict.fromDaemonStatus(Data("not json".utf8)) == nil)
    }

    @Test func anAcpmuxWithoutAVerdictIsAskedRarely() async {
        let asks = Counter()
        let source = LocalHostPressureSource(host: "gray") { await asks.bump(); return nil }
        for _ in 0 ..< LocalHostPressureSource.acpmuxRetryReads + 1 { _ = await source.acpmuxVerdict() }
        #expect(await asks.value == 2)
    }

    /// The contract's fixtures: every perf level but Efficiency counts (M5 and M6 report a Super tier first).
    @Test(arguments: [
        ("cosmic-gray", [("Super", 5), ("Performance", 10)], 15),
        ("air-blue", [("Super", 4), ("Efficiency", 6)], 4),
        ("cmux16", [("Super", 2), ("Performance", 4), ("Efficiency", 6)], 6),
    ])
    func performanceCoresSkipOnlyEfficiency(host: String, levels: [(String, Int32)], expected: Int) {
        var ints: [String: Int32] = ["hw.nperflevels": Int32(levels.count)]
        var names: [String: String] = [:]
        for (index, level) in levels.enumerated() {
            ints["hw.perflevel\(index).physicalcpu"] = level.1
            names["hw.perflevel\(index).name"] = level.0
        }
        #expect(HostSampler.performanceCores(int: { ints[$0] }, string: { names[$0] }) == expected, "\(host)")
    }

    @Test func noPerfLevelsMeansNoPerformanceCount() {
        #expect(HostSampler.performanceCores(int: { _ in nil }, string: { _ in nil }) == nil)
        #expect(HostSampler.performanceCores(int: { $0 == "hw.nperflevels" ? 2 : nil }, string: { _ in nil }) == nil)
    }

    @Test func theSwapRateIsPerMinute() {
        var rate = SwapRate()
        #expect(rate.feed(bytes: 0, seconds: 0) == nil)
        #expect(rate.feed(bytes: 32 << 20, seconds: 15) == 128)
        #expect(rate.feed(bytes: 0, seconds: 30) == nil)
    }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
