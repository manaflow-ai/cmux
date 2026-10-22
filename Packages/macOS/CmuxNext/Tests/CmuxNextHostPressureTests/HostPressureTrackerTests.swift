import Foundation
@testable import CmuxNextHostPressure
import Testing

/// The warning and the banner come from the shared host budget (12 performance
/// cores here, so a load limit of 12) and do not flicker.
struct HostPressureTrackerTests {
    private func verdict(load: Double = 2, pressure: HostMemoryPressure = .normal, swap: Double = 0) -> HostBudgetVerdict {
        HostBudgetVerdict(host: "gray", cores: 12, load1: load, loadLimit: 12, pressure: pressure, swapMBPerMin: swap, swapLimit: 64)
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
        (12.0, HostMemoryPressure.normal, 0.0, HostPressureLevel.warning),
        (2, .warn, 0, .warning),
        (2, .normal, 64, .warning),
        (2, .critical, 0, .critical),
        (146, .warn, 0, .critical),
        (2, .warn, 200, .critical),
        (146, .normal, 0, .warning),
    ])
    func eachPartOfTheBudget(load: Double, pressure: HostMemoryPressure, swap: Double, level: HostPressureLevel) {
        #expect(HostPressureTracker.level(for: verdict(load: load, pressure: pressure, swap: swap), holding: .normal) == level)
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
        #expect(sampled.over == ["cpu", "swap"])
        let newer = sampled.with(pressure: .warn)
        #expect(newer.over == ["cpu", "memory", "swap"])
        #expect(newer.with(pressure: .normal).over == ["cpu", "swap"])
        #expect(!newer.ok)
    }
}

/// The formula is derived from the host and an optional override file, in the contract's order.
struct HostBudgetFormulaTests {
    @Test func theDefaultsAreTheContracts() {
        let formula = HostBudgetFormula()
        #expect(formula.loadLimit(cores: 12) == 12)
        #expect(formula.cores == "performance")
        #expect(formula.swapGrowthMBPerMin == 64)
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

    @Test func theEnvironmentPathComesFirst() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(HostBudgetFile.path(environment: ["ACPMUX_HOST_BUDGET": "/etc/budget.json"], home: home).path == "/etc/budget.json")
        #expect(HostBudgetFile.path(environment: [:], home: home).path == "/Users/someone/.config/cmux/host-budget.json")
    }

    @Test func aMissingFileKeepsTheDefaults() {
        let formula = HostBudgetFile.loadFormula(host: "x", environment: ["ACPMUX_HOST_BUDGET": "/nonexistent/budget.json"])
        #expect(formula == HostBudgetFormula())
    }

    @Test func acpmuxsVerdictDecodes() throws {
        let json = #"{"host":"gray","cores":12,"load1":146.2,"load_limit":12,"pressure":"warn","swap_mb_per_min":90,"over":["cpu","memory","swap"],"ok":false}"#
        let verdict = try JSONDecoder().decode(HostBudgetVerdict.self, from: Data(json.utf8))
        #expect(verdict.loadLimit == 12)
        #expect(verdict.pressure == .warn)
        #expect(HostPressureTracker.level(for: verdict, holding: .normal) == .critical)
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

    @Test func theSwapRateIsPerMinute() {
        var rate = SwapRate()
        #expect(rate.feed(bytes: 0, seconds: 0) == 0)
        #expect(rate.feed(bytes: 32 << 20, seconds: 15) == 128)
        #expect(rate.feed(bytes: 0, seconds: 30) == 0)
    }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
