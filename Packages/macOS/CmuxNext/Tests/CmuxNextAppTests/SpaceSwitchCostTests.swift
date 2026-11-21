import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextSidebar
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

    /// "changing spaces in sidebar also feels kinda slow" (Lawrence 2026-11-10). What a switch paid for nothing:
    /// a second list for the space it left (the page that slid out: a layout of every row of that space and a
    /// view for each row on screen), and three main-actor turns before the list drew (the content swap, the
    /// sidebar's rows, the list's render, each on its own observation). In a window the app holds, with 10 and
    /// with 200 workspaces in each space, a switch lays out the new space's rows once and shows them in its own
    /// turn. The printed line is the measure: `wall_ms` is from the switch to the flushed frame, in process.
    @Test(arguments: [20, 400])
    func aSwitchLaysOutTheNewSpaceOnceInItsOwnTurn(_ total: Int) async throws {
        let perSpace = total / 2
        let bench = try await SpaceSwitchBench(total: total, registered: true)
        defer { bench.close() }
        let samples = try await bench.run(rounds: 40)
        print(SpaceSwitchBench.summary(total, samples) + " | registered mounted=\(bench.mounted)")
        for (round, sample) in samples.enumerated() {
            let count = { (name: String) in sample.counters[name] ?? 0 }
            #expect(count("spins") == 0, "switch \(round): the sidebar showed the space \(count("spins")) turns after the switch")
            #expect(count("list_reloads") == 1, "switch \(round): \(count("list_reloads")) list layouts for one space")
            #expect(count("layout_rows") <= perSpace + 8, "switch \(round): laid out \(count("layout_rows")) rows to show \(perSpace)")
        }
    }

    /// Not a check: where the same-turn switch of a window the app holds spends its main-thread time, at 200
    /// workspaces in each space. Opt-in with `CMUX_SAMPLE_PROFILE=1` (`SelfSampler`).
    @Test(.enabled(if: SelfSampler.enabled, "self-sampling profile; set CMUX_SAMPLE_PROFILE=1"))
    func profileOfASameTurnSpaceSwitch() async throws {
        let bench = try await SpaceSwitchBench(total: 400, registered: true)
        defer { bench.close() }
        _ = try await bench.run(rounds: 1)
        try await bench.profile(rounds: 150, seconds: 9, minimum: 60)
    }

    /// "changing spaces in sidebar also feels kinda slow" (Lawrence 2026-11-10), the part a switch still paid after
    /// it moved into the input's turn: the rows feed forgot every row of the space the window left and mapped
    /// every row of the space it showed again (`row_maps` 200 for a list that draws about 29 rows), each with its
    /// own observation, on every switch. A space the window showed before maps only the rows that changed while
    /// it was hidden: a switch back builds no more rows than the list draws.
    @Test func aSwitchBackToASpaceBuildsNoMoreRowsThanTheListDraws() async throws {
        let bench = try await SpaceSwitchBench(total: 400, registered: true)
        defer { bench.close() }
        let samples = try await bench.run(rounds: 12)
        print(SpaceSwitchBench.summary(400, samples) + " | registered revisit")
        for (round, sample) in samples.enumerated() {
            let count = { (name: String) in sample.counters[name] ?? 0 }
            #expect(count("row_frames") > 0 && count("row_frames") < 60, "switch \(round): the list drew \(count("row_frames")) rows")
            #expect(count("row_maps") <= count("row_frames") + 8,
                    "switch \(round): built \(count("row_maps")) rows of a space shown before; the list draws \(count("row_frames"))")
        }
    }

    /// The window opened at launch adopts a saved window's id (`WindowState.adopt`) and keeps its sidebar: what the
    /// rows feed keeps follows the id the window has now. With the id read once at the start, the person's main
    /// window kept no row after a relaunch and every switch mapped every row of the space again.
    @Test func theRowsFeedKeepsTheWorkspacesOfTheIdTheLaunchWindowAdopted() async throws {
        let bench = try await SpaceSwitchBench(total: 4, registered: true)
        defer { bench.close() }
        let record = { (id: String) in try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"\#(id)","workspace_key":"k0"}"#.utf8)) }
        let launch = try WindowState(record: record("launch"))
        let bridge = SidebarBridge(services: bench.services, state: launch)
        defer { bridge.teardown() }
        let feed = bridge.rowFeed
        try launch.adopt(record("space-bench"))
        // Three passes of the sidebar's feed: the space of workspace k0 shows, another space shows, k0's shows again.
        let workspace = CmuxNextSidebar.WorkspaceID("k0")
        final class Count { var maps = 0 }
        let count = Count()
        for named in [true, false, true] {
            feed.beginPass(inputs: 0)
            if named {
                _ = feed.row(workspace, machine: .local) {
                    count.maps += 1
                    return SidebarWorkspace(id: workspace, machineID: .local, title: "k0")
                }
            }
            _ = feed.fill([])
        }
        #expect(count.maps == 1, "the launch window has the saved window's id and mapped the row of its own workspace \(count.maps) times")
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
