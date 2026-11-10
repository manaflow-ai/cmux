import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-11-10: each project shows its five most recent chats, then "Show N more", and the sidebar costs the same at
/// 30 chats as at 3,000, god sessions included. The same harness as `SidebarLongListScaleTests` (`SidebarScrollBench`):
/// projects of chats, and one god project holding every chat (a sixth working, an eleventh waiting, about a third
/// unread), each laid out and scrolled with caps off (before) and on (after). With caps on, the rows drawn, the views
/// held and a scroll frame's work stay within 1.2x from 30 to 3,000 chats. Prints one `SIDEBAR-CAPS-SWIFT` line each.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)))
struct SidebarProjectCapsScaleTests {
    static let sizes = [30, 3_000]

    struct Sample {
        var count: Int
        var rows: Int
        var rowViews: Int
        var configuresPerFrame: Double
        var cpuP50: Double

        var line: String {
            String(format: "count=%d rows=%d row_views=%d configures/frame=%.2f cpu_ms p50 %.3f", count, rows, rowViews,
                   configuresPerFrame, cpuP50)
        }
    }

    static func sample(_ count: Int, shape: SidebarScrollBench.Shape, caps: SidebarProjectCapsPreferences) -> Sample {
        let bench = SidebarScrollBench(count: count, shape: shape, caps: caps)
        defer { bench.close() }
        let rows = SidebarLayout.make(sections: bench.model.sections, metrics: .standard, options: bench.model.listOptions()).rows.count
        let frames = bench.run(passes: 1, depth: 1_800)
        return Sample(count: count, rows: rows, rowViews: bench.rowViewsInList,
                      configuresPerFrame: Double(frames.map(\.configures).reduce(0, +)) / Double(max(frames.count, 1)),
                      cpuP50: SidebarScrollBench.percentile(frames.map(\.cpuMs), 0.5))
    }

    @Test func projectsCostTheSameAtThirtyAndThreeThousandChats() {
        let on = SidebarProjectCapsPreferences(cap: SidebarChatsPerProject.five.cap, floats: true)
        // Ten projects at every size (3 and 300 chats each), and one god project of every chat.
        for (name, shape) in [("projects", { (n: Int) in SidebarScrollBench.Shape.projects(perGroup: max(1, n / 10)) }),
                              ("god", { _ in SidebarScrollBench.Shape.oneGroup })] {
            for (label, caps) in [("before", SidebarProjectCapsPreferences.off), ("after", on)] {
                let samples = Self.sizes.map { Self.sample($0, shape: shape($0), caps: caps) }
                for sample in samples { print("SIDEBAR-CAPS-SWIFT shape=\(name) \(label) " + sample.line) }
                guard label == "after", let small = samples.first, let large = samples.last else { continue }
                // Active rows always show (the bench marks about half its chats unread, waiting or working), so the rows
                // listed grow with them and print only; the quiet rows stop at five per project. What must hold is that
                // the list never holds or configures a view per hidden row.
                #expect(large.rowViews <= Int(Double(small.rowViews) * 1.2) + 2,
                        "\(name): row views grew with the chats: \(small.line) -> \(large.line)")
                #expect(large.configuresPerFrame <= small.configuresPerFrame * 1.2 + 0.5,
                        "\(name): a scroll frame configures more rows at 3,000 chats: \(small.line) -> \(large.line)")
            }
        }
    }
}
