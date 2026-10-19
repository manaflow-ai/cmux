import AppKit
@testable import CmuxNextApp
import Foundation
import Testing

/// "If I have a lot of workspaces open, changing spaces causes a bit of lag" (space-switch-fast):
/// a space switch in the sidebar costs what the new space shows, not every workspace the window
/// holds. Each test drives the real switch (`WindowManager.switchProfile`) in a window whose
/// spaces hold 5, 50 and 250 workspaces each (10, 100 and 500 in all) and prints one
/// `SPACE-SWITCH-BENCH` line per size (BASELINE.md). The guard compares main-thread CPU per switch
/// at 500 with 10 workspaces: the switch must not grow with the count of workspaces.
@MainActor @Suite(.serialized)
struct SpaceSwitchCostTests {
    static let sizes = [10, 100, 500]

    static func measure(_ total: Int, panes: Bool = false, parked: Int = 0, rounds: Int = 30) async throws -> [SpaceSwitchBench.Sample] {
        let bench = try await SpaceSwitchBench(total: total, panes: panes, parked: parked)
        defer { bench.close() }
        let samples = try await bench.run(rounds: rounds)
        print(SpaceSwitchBench.summary(total, samples) + " | panes=\(panes) mounted=\(bench.mounted)")
        return samples
    }

    @Test func aSpaceSwitchCostsTheSameAt500WorkspacesAsAt10() async throws {
        var p50: [Int: Double] = [:]
        for total in Self.sizes {
            let samples = try await Self.measure(total)
            p50[total] = SpaceSwitchBench.percentile(samples.map(\.cpuMs), 0.5)
        }
        let small = try #require(p50[10]), large = try #require(p50[500])
        // O(visible): a constant 4 ms of slack covers the rows a taller space realizes and timer noise.
        #expect(large <= small * 2 + 4, "a space switch at 500 workspaces took \(large) ms of main thread vs \(small) ms at 10")
    }

    /// Every workspace has a terminal and a browser tab and was shown once (mounted, parked).
    @Test func aSpaceSwitchWithParkedWorkspacesCostsTheSameAt500AsAt10() async throws {
        var p50: [Int: Double] = [:]
        for total in Self.sizes {
            let samples = try await Self.measure(total, panes: true, parked: total, rounds: 20)
            p50[total] = SpaceSwitchBench.percentile(samples.map(\.cpuMs), 0.5)
        }
        let small = try #require(p50[10]), large = try #require(p50[500])
        #expect(large <= small * 2 + 4, "a space switch over 500 parked workspaces took \(large) ms of main thread vs \(small) ms at 10")
    }
}
