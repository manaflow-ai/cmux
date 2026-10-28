import AppKit
@testable import CmuxNextApp
import Foundation
import Testing

/// "Need to make sure changing spaces and screens, when there's a lot of workspaces, groups, tabs, terminals, panes
/// etc, is extremely fast" (Lawrence 2026-10-28, switch-scale.md). Every switch kind over the switch-at-scale fixture
/// at 10 and 1,000 workspaces (SwitchScaleBench): one `SWITCH-SCALE` line per kind and size, result-v1 with
/// CMUX_PERF_RESULT_DIR (lab story swift-switch-scale), and the checks that the switch is O(visible): its main-thread
/// time at 1,000 workspaces is the same as at 10, and memory stays flat over 1,000 switches.
///
/// A bench: it runs only with CMUX_SWITCH_SCALE_BENCH=1 (the story and a person's fleet step set it), never in the
/// package suites. CMUX_SWITCH_SCALE_ROUNDS sets the switches per kind (default 200).
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_SWITCH_SCALE_BENCH"] == "1",
                                        "a bench: CMUX_SWITCH_SCALE_BENCH=1"))
struct SwitchScaleCostTests {
    static var rounds: Int { Int(ProcessInfo.processInfo.environment["CMUX_SWITCH_SCALE_ROUNDS"] ?? "") ?? 200 }

    /// Every kind at `size`: the per-kind samples, printed and recorded.
    static func measure(_ size: Int, rounds: Int, records: Bool = true) async throws -> [SwitchScaleBench.Kind: [SwitchScaleBench.Sample]] {
        let bench = try await SwitchScaleBench(workspaces: size)
        defer { bench.close() }
        let counts = bench.fixture.counts, footprint = await SwitchScaleBench.footprint()
        print("SWITCH-SCALE-FIXTURE n=\(size) spaces=\(bench.fixture.spaces) groups=\(bench.fixture.groups.count) screens=\(counts.screens) "
              + "panes=\(counts.panes) tabs=\(counts.tabs) windows=\(bench.controllers.count) footprint=\(footprint)")
        var out: [SwitchScaleBench.Kind: [SwitchScaleBench.Sample]] = [:]
        for kind in SwitchScaleBench.Kind.allCases {
            let samples = await bench.run(kind, rounds: rounds)
            print(SwitchScaleBench.line(size, kind, samples, mounted: bench.main.mountedContents.count))
            if records { try SwitchScaleBench.record(size, kind, samples) }
            out[kind] = samples
        }
        return out
    }

    @Test func everySwitchKindAt10Workspaces() async throws { _ = try await Self.measure(10, rounds: Self.rounds) }

    @Test func everySwitchKindAt1000Workspaces() async throws { _ = try await Self.measure(1000, rounds: Self.rounds) }

    /// The guard: each kind's p50 main-thread time at 1,000 workspaces is at most 1.5x its time at 10 plus 1 ms, and
    /// every switch showed its content.
    @Test func aSwitchCostsTheSameAt1000WorkspacesAsAt10() async throws {
        let rounds = min(Self.rounds, 40)
        // Not recorded: the two tests above own the result-v1 series (a metric recorded twice is refused).
        let small = try await Self.measure(10, rounds: rounds, records: false)
        let large = try await Self.measure(1000, rounds: rounds, records: false)
        for kind in SwitchScaleBench.Kind.allCases {
            let at10 = SwitchScaleBench.percentile((small[kind] ?? []).map(\.cpuMs), 0.5)
            let at1000 = SwitchScaleBench.percentile((large[kind] ?? []).map(\.cpuMs), 0.5)
            #expect(at1000 <= at10 * 1.5 + 1, "\(kind.rawValue): \(at1000) ms of main thread per switch at 1,000 workspaces vs \(at10) ms at 10")
            let missed = (large[kind] ?? []).filter { !$0.shown }.count
            #expect(missed == 0, "\(kind.rawValue): \(missed) switches at 1,000 workspaces never showed their content")
        }
    }

    /// 1,000 workspace switches over 20 workspaces of the main window's space: the footprint after them is within
    /// 32 MB of the footprint after the first 100, and the mounted workspaces stay bounded.
    @Test func memoryStaysFlatOver1000Switches() async throws {
        let bench = try await SwitchScaleBench(workspaces: 1000)
        defer { bench.close() }
        let keys = Array((bench.keysByRoom[SwitchScaleFixture.room(0)] ?? []).prefix(20))
        try #require(keys.count == 20)
        var marks: [UInt64] = []
        for round in 0..<1000 {
            let target = keys[round % keys.count]
            _ = await bench.timed({ bench.services.windows.show(workspaceID: target, in: bench.main.state, from: .thisWindow) },
                                  shown: { bench.shownWorkspace == target })
            if round % 100 == 99 { marks.append(await SwitchScaleBench.footprint()) }
        }
        let mounted = bench.main.mountedContents.count
        print("SWITCH-SCALE-MEMORY n=1000 switches=1000 footprint_mb=" + marks.map { String($0 >> 20) }.joined(separator: ",") + " mounted=\(mounted)")
        let first = try #require(marks.first), last = try #require(marks.last)
        #expect(last <= first + 32 << 20, "the footprint grew \((Int64(last) - Int64(first)) >> 20) MB over 900 switches")
        #expect(mounted <= 12, "\(mounted) workspaces stay mounted after visiting 20 (want a bounded LRU)")
    }

    /// Not a check: where each kind's switch spends its main-thread time at 1,000 workspaces.
    @Test func profileOfEverySwitchKindAt1000Workspaces() async throws {
        let bench = try await SwitchScaleBench(workspaces: 1000)
        defer { bench.close() }
        for kind in SwitchScaleBench.Kind.allCases {
            bench.settle()
            try await bench.profile(kind, rounds: 60, seconds: 6)
        }
    }
}
