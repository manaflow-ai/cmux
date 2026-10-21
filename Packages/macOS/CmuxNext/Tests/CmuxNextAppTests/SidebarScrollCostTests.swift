import AppKit
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-20: "I was just scrolling the sidebar and I encountered a ton of lag." A
/// scroll only moves rows that are already laid out and draws the few that come into view: each
/// frame stays inside half a 60 Hz frame (8 ms of main thread) at 500 workspaces, and a scroll
/// never lays the list out again. Prints one `SIDEBAR-SCROLL-BENCH` line per size
/// (sidebar-scroll-perf-DESIGN.md).
@MainActor @Suite(.serialized)
struct SidebarScrollCostTests {
    static func measure(_ count: Int, pointer: Bool = false, ticks: Int = 0, moveToTopEvery: Int = 0) -> [SidebarScrollBench.Frame] {
        let bench = SidebarScrollBench(count: count, pointerOverList: pointer)
        defer { bench.close() }
        bench.ticksPerFrame = ticks
        bench.moveToTopEvery = moveToTopEvery
        let frames = bench.run()
        print(SidebarScrollBench.summary(count, frames) + " | pointer=\(pointer) ticks=\(ticks) moveToTopEvery=\(moveToTopEvery)")
        return frames
    }

    /// A scroll keeps few row views in the list: the visible rows, a short overscan and a pool of
    /// parked views for the next rows, not tenfold the visible rows (each view's subtree costs
    /// every frame).
    @Test func aScrolledListHoldsAFewScreensOfRowViews() {
        let bench = SidebarScrollBench(count: 500)
        defer { bench.close() }
        _ = bench.run(passes: 1)
        let held = bench.rowViewsInList, visible = bench.visibleRows
        print("SIDEBAR-SCROLL-VIEWS n=500 visible=\(visible) held=\(held)")
        #expect(held <= visible * 2, "the list holds \(held) row views for \(visible) visible rows")
    }

    @Test func scrollingFiveHundredWorkspacesStaysInsideTheFrameBudget() {
        for count in [10, 100] { _ = Self.measure(count) }
        for pointer in [false, true] {
            let frames = Self.measure(500, pointer: pointer)
            let p95 = SidebarScrollBench.percentile(frames.map(\.cpuMs), 0.95)
            #expect(p95 < 8, "p95 scroll frame at 500 workspaces (pointer over the list: \(pointer)) took \(p95) ms of main thread")
            #expect(frames.map(\.reloads).reduce(0, +) == 0, "a scroll laid the list out again (pointer: \(pointer))")
        }
        // Agents streaming while the list scrolls: three status ticks a frame.
        let ticking = Self.measure(500, pointer: true, ticks: 3)
        let tickingP95 = SidebarScrollBench.percentile(ticking.map(\.cpuMs), 0.95)
        #expect(tickingP95 < 8, "p95 scroll frame at 500 workspaces with ticking agents took \(tickingP95) ms of main thread")
        // Not a check: a notification moving a workspace to the top every half second.
        _ = Self.measure(500, pointer: true, ticks: 3, moveToTopEvery: 60)
    }
}

/// Not a check: where a sidebar scroll frame spends its main-thread time (its own suite, so the
/// sampler has a suite timeout of its own).
@MainActor @Suite(.serialized)
struct SidebarScrollProfile {
    /// Not a check: where a scroll frame spends its main-thread time.
    @Test func profileOfASidebarScroll() async throws {
        let bench = SidebarScrollBench(count: 500, pointerOverList: true)
        defer { bench.close() }
        bench.ticksPerFrame = 3
        _ = bench.run(passes: 1)
        try await bench.profile(seconds: 5)
    }

    /// Not a check: where a scroll spends its time when notifications move workspaces to the top
    /// (`notifications.attention.moveToTop`, on by default) every few frames.
    @Test func profileOfASidebarScrollWithMovesToTop() async throws {
        let bench = SidebarScrollBench(count: 500, pointerOverList: true)
        defer { bench.close() }
        bench.moveToTopEvery = 4
        _ = bench.run(passes: 1)
        try await bench.profile(seconds: 5)
    }
}
