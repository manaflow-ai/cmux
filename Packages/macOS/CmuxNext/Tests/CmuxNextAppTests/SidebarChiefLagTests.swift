import AppKit
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-27: "so i guess our other benches hadn't reached that? hm. did we map out all the benches of
/// everything else too?" SidebarLagBench and SidebarScrollBench drew a sidebar with no Chiefs and no
/// settings file, so the 2-6 s beachball at 1104 Chief-started chats and a ~160 KB cmux.json never showed in
/// them. Here both run at 1104 workspaces twice: the sidebar alone (`before`), then with `SidebarChiefFixture`
/// as the app's side of every tick (`after`): five Chiefs owning every chat, the big settings file, and the
/// row mapping with the Chief avatar SidebarBridge passes, all on the main thread inside the frame.
/// Prints `SIDEBAR-CHIEF-LAG` lines and fails when a ticking frame with Chiefs stalls.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct SidebarChiefLagTests {
    static let workspaces = 1104
    /// A ticking frame with Chiefs: a few frames at worst, never a hitch you see (the app's beachball was
    /// 2-6 s). p95 stays inside two 60 Hz frames.
    static let worstBudgetMs = 250.0, p95BudgetMs = 33.0

    static func line(_ label: String, _ bench: String, _ frames: [Double], _ fixture: SidebarChiefFixture?) -> String {
        let p50 = SidebarLagBench.percentile(frames, 0.5), p95 = SidebarLagBench.percentile(frames, 0.95)
        var s = String(format: "SIDEBAR-CHIEF-LAG %@ %@ n=%d frames=%d p50_ms=%.2f p95_ms=%.2f max_ms=%.2f over16ms=%d",
                       bench, label, workspaces, frames.count, p50, p95, frames.max() ?? 0, frames.filter { $0 > 16 }.count)
        if let fixture { s += " chiefs=\(SidebarChiefFixture.chiefs.count) config_bytes=\(fixture.configBytes) avatar_calls=\(fixture.avatarCalls)" }
        return s
    }

    static func lag(_ fixture: SidebarChiefFixture?) -> [Double] {
        let bench = SidebarLagBench(count: workspaces)
        defer { bench.close() }
        if let fixture { bench.appTick = { fixture.appTick(&$0, $1) } }
        return bench.run(.ticks).map(\.cpuMs)
    }

    static func scroll(_ fixture: SidebarChiefFixture?) -> [Double] {
        let bench = SidebarScrollBench(count: workspaces, pointerOverList: true)
        defer { bench.close() }
        bench.ticksPerFrame = 3
        if let fixture { bench.appTick = { fixture.appTick(&$0, $1) } }
        return bench.run(depth: SidebarScrollCostTests.scrollDepth).map(\.cpuMs)
    }

    func check(_ bench: String, _ after: [Double]) {
        let worst = after.max() ?? 0, p95 = SidebarLagBench.percentile(after, 0.95)
        #expect(worst < Self.worstBudgetMs, "a \(bench) frame with Chiefs took \(Int(worst)) ms at \(Self.workspaces) workspaces (budget \(Int(Self.worstBudgetMs)))")
        #expect(p95 < Self.p95BudgetMs, "\(bench) frames with Chiefs: p95 \(String(format: "%.1f", p95)) ms at \(Self.workspaces) workspaces (budget \(Int(Self.p95BudgetMs)))")
    }

    @Test func tickingFramesWithChiefsAndABigConfigStayUnderBudget() async throws {
        let fixture = try await SidebarChiefFixture.make(workspaces: Self.workspaces)
        defer { fixture.tearDown() }
        #expect(fixture.configBytes > 150_000, "the fixture needs Lawrence's settings size")
        #expect(fixture.lanes.chiefParticipants.count == SidebarChiefFixture.chiefs.count, "every Chief owns its children")
        #expect(fixture.ids.count == Self.workspaces, "the feed mapped \(fixture.ids.count) rows")
        #expect(fixture.mapped.values.contains { $0.chiefAvatar != nil }, "no mapped row has a Chief avatar")

        print(Self.line("before", "ticks", Self.lag(nil), nil))
        fixture.resetCounts()
        let lagAfter = Self.lag(fixture)
        #expect(fixture.avatarCalls > 0, "the ticks mapped no Chief-owned row")
        print(Self.line("after", "ticks", lagAfter, fixture))

        print(Self.line("before", "scroll", Self.scroll(nil), nil))
        fixture.resetCounts()
        let scrollAfter = Self.scroll(fixture)
        print(Self.line("after", "scroll", scrollAfter, fixture))

        // A settings change maps every row again (ChiefFaceFlushBenchTests times that pass alone).
        fixture.resetCounts()
        let start = SidebarLagBench.threadCPU()
        fixture.remap()
        let remapMs = (SidebarLagBench.threadCPU() - start) * 1_000
        print(String(format: "SIDEBAR-CHIEF-LAG remap after n=%d full_pass_ms=%.1f avatar_calls=%d", Self.workspaces, remapMs, fixture.avatarCalls))

        check("ticks", lagAfter)
        check("scroll", scrollAfter)
    }
}
