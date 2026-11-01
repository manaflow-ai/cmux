import AppKit
@testable import CmuxNextApp
import Foundation
import Testing

/// "If I have a lot of workspaces open, changing spaces causes a bit of lag" (space-switch-fast):
/// a space switch in the sidebar costs what the new space shows, not every workspace the window
/// holds. Each test drives the real switch (`WindowManager.switchProfile`) in a window whose
/// spaces hold 5, 50 and 250 workspaces each (10, 100 and 500 in all) and prints one
/// `SPACE-SWITCH-BENCH` line per size (BASELINE.md). The guard compares main-thread CPU per switch
/// at 500 with 100 workspaces: the switch must not grow with the count of workspaces.
@MainActor @Suite(.serialized)
struct SpaceSwitchCostTests {
    static func measure(_ total: Int, panes: Bool = false, parked: Int = 0, rounds: Int = 8) async throws -> [SpaceSwitchBench.Sample] {
        let bench = try await SpaceSwitchBench(total: total, panes: panes, parked: parked)
        defer { bench.close() }
        let samples = try await bench.run(rounds: rounds)
        print(SpaceSwitchBench.summary(total, samples) + " | panes=\(panes) mounted=\(bench.mounted)")
        return samples
    }

    static func p50(_ samples: [SpaceSwitchBench.Sample]) -> Double { SpaceSwitchBench.percentile(samples.map(\.cpuMs), 0.5) }

    /// Not a check: where a switch spends its main-thread time (BASELINE.md), with 120 parked
    /// workspaces of a terminal and a browser tab each, and with 500 plain ones. Opt-in with
    /// `CMUX_SAMPLE_PROFILE=1` (`SelfSampler`); the checks below run by default.
    @Test(.enabled(if: SelfSampler.enabled, "self-sampling profile; set CMUX_SAMPLE_PROFILE=1"))
    func profileOfASpaceSwitch() async throws {
        let parked = try await SpaceSwitchBench(total: 120, panes: true, parked: 120)
        _ = try await parked.run(rounds: 1)
        try await parked.profile(rounds: 30, seconds: 8)
        parked.close()
        let plain = try await SpaceSwitchBench(total: 500)
        _ = try await plain.run(rounds: 1)
        try await plain.profile(rounds: 30, seconds: 8)
        plain.close()
    }

    /// 10 and 60 workspaces (5 and 30 per space) show fewer rows than the sidebar and its overscan
    /// hold; at 100 every space fills them, so from there a switch must cost the same: what is on
    /// screen, not how many workspaces exist.
    @Test(.disabled("Quarantined: 500 vs 100 sits on the 1.5x line and flakes 2/6 on CI, https://github.com/manaflow-ai/cmux/issues/30974"))
    func aSpaceSwitchCostsTheSameAt500WorkspacesAsAt100() async throws {
        var results: [Int: [SpaceSwitchBench.Sample]] = [:]
        for total in [10, 60, 100, 500] { results[total] = try await Self.measure(total) }
        let small = try #require(results[100]), large = try #require(results[500])
        #expect(Self.p50(large) <= Self.p50(small) * 1.5 + 4, "a space switch at 500 workspaces took \(Self.p50(large)) ms of main thread vs \(Self.p50(small)) ms at 100")
        let configures = { (samples: [SpaceSwitchBench.Sample]) in samples.map { $0.counters["row_configures"] ?? 0 }.max() ?? 0 }
        #expect(configures(large) <= configures(small) + 4, "a switch at 500 configured \(configures(large)) rows vs \(configures(small)) at 100")
    }

    /// Every workspace has a terminal and a browser tab and was shown once (mounted, parked): a
    /// switch must not wake every parked workspace. 60 workspaces (30 per space) do not fill the
    /// sidebar and 120 do, so the check is the main-thread cost per realized row.
    @Test func aSpaceSwitchCostsTheSameWith120ParkedWorkspacesAsWith60() async throws {
        var results: [Int: [SpaceSwitchBench.Sample]] = [:]
        for total in [10, 60, 120] { results[total] = try await Self.measure(total, panes: true, parked: total, rounds: 6) }
        let small = try #require(results[60]), large = try #require(results[120])
        let perRow = { (samples: [SpaceSwitchBench.Sample]) -> Double in
            let rows = samples.map { Double($0.counters["row_configures"] ?? 0) }.reduce(0, +) / Double(max(samples.count, 1))
            return Self.p50(samples) / max(rows, 1)
        }
        #expect(perRow(large) <= perRow(small) * 1.5 + 0.1, "a space switch over 120 parked workspaces took \(perRow(large)) ms per realized row vs \(perRow(small)) ms over 60")
    }
}
