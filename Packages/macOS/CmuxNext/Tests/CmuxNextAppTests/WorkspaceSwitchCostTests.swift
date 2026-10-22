import AppKit
@testable import CmuxNextApp
import Foundation
import QuartzCore
import Testing

/// Lawrence 2026-10-21: "switching workspaces is very slow, we need to make it speed of light". A workspace switch
/// costs what the window shows, not every workspace it ever showed: the fleet perf gate measured a warm switch at
/// 150 workspaces at 36 ms p50 of main thread (2.4 ms at 10), all of it in AppKit's layer-tree build and window
/// ordering over the hidden view trees of every parked workspace. Each test drives the real switch
/// (`WindowManager.select` + `WindowController.showWorkspace`, the path every entry point ends in) through the
/// layout, display and Core Animation commit, in a window whose workspaces each hold a terminal and a browser tab
/// and were all shown once, and prints one `WORKSPACE-SWITCH-BENCH` line per size.
@MainActor @Suite(.serialized)
struct WorkspaceSwitchCostTests {
    struct Sample { var cpuMs: Double; var wallMs: Double }

    /// `rounds` switches around the 4 most recently shown workspaces (the set a person moves between).
    static func measure(_ total: Int, rounds: Int = 24) async throws -> (samples: [Sample], mounted: Int) {
        let bench = try await SpaceSwitchBench(total: total, spaces: 1, panes: true, parked: total)
        defer { bench.close() }
        let keys = (max(0, total - 4)..<total).map { "k\($0)" }
        for key in keys { switchTo(key, bench) } // warm-up: each of the four mounts or unparks once
        var samples: [Sample] = []
        for round in 0..<rounds { samples.append(switchTo(keys[round % keys.count], bench)) }
        let p50 = SpaceSwitchBench.percentile(samples.map(\.cpuMs), 0.5), p95 = SpaceSwitchBench.percentile(samples.map(\.cpuMs), 0.95)
        print("WORKSPACE-SWITCH-BENCH total=\(total) mounted=\(bench.mounted) cpu p50=\(String(format: "%.2f", p50)) ms p95=\(String(format: "%.2f", p95)) ms")
        return (samples, bench.mounted)
    }

    /// One switch to `key`, through the frame that shows it.
    @discardableResult
    static func switchTo(_ key: String, _ bench: SpaceSwitchBench) -> Sample {
        let cpu0 = SpaceSwitchBench.threadCPU(), wall0 = CACurrentMediaTime()
        bench.services.windows.select(key, in: bench.state)
        bench.controller.showWorkspace(requested: bench.state.workspaceID)
        bench.controller.window?.contentView?.layoutSubtreeIfNeeded()
        bench.controller.window?.displayIfNeeded()
        CATransaction.flush()
        let sample = Sample(cpuMs: (SpaceSwitchBench.threadCPU() - cpu0) * 1_000, wallMs: (CACurrentMediaTime() - wall0) * 1_000)
        bench.drain()
        return sample
    }

    @Test func aWindowKeepsOnlyItsRecentWorkspacesMounted() async throws {
        let (_, mounted) = try await Self.measure(40, rounds: 4)
        // The recently used set: 8 parked beside the shown one (`WindowController.parkedCapacity`).
        #expect(mounted <= 9, "\(mounted) workspaces mounted after 40 were shown (want the shown one and at most 8 parked)")
    }

    @Test func aWarmSwitchCostsTheSameAt150WorkspacesAsAt10() async throws {
        let small = try await Self.measure(10), large = try await Self.measure(150)
        let p50 = { (s: [Sample]) in SpaceSwitchBench.percentile(s.map(\.cpuMs), 0.5) }
        #expect(p50(large.samples) <= p50(small.samples) * 1.5 + 2,
                "a warm switch at 150 workspaces took \(p50(large.samples)) ms of main thread vs \(p50(small.samples)) ms at 10")
    }
}
