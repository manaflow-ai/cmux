import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Sticky project headers (Leo, 2026-11-10: "Obviously we want infinite scroll ... you also don't want to make a, like a
/// scrollable area within a scrollable area"). The sidebar is the one scroll area; while it scrolls through an open
/// group, the group's own header view stays at the top of the visible rows on the gallery's `veil` until the group's last
/// row pushes it up. At rest it draws as before. Clicking it collapses the group with the header left where it is, at
/// its own place at the top. The scroll costs the same through a group of 3,000 as through one of 30 (`SIDEBAR-STICKY`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)))
struct SidebarStickyHeaderTests {
    static let group = GroupID("sb-g0")

    static func top(_ bench: SidebarScrollBench) -> CGFloat { bench.clip.bounds.minY + bench.list.stickyTopInset }

    static func header(_ bench: SidebarScrollBench, _ id: GroupID = group) throws -> (view: SidebarRowView, row: SidebarRow) {
        let row = try #require(bench.list.displayed.row(for: .group(id)), "the group's header is listed")
        let view = try #require(bench.list.rowViews[.group(id)], "the header has a view")
        return (view, row)
    }

    @Test func aLongGroupsHeaderStaysAtTheTopWhileItsRowsScrollUnderIt() throws {
        let bench = SidebarScrollBench(count: 300, shape: .oneGroup)
        defer { bench.close() }
        let sidebar = bench.sidebar
        // At rest: its own place, no veil, the top fade as before.
        let rest = try Self.header(bench)
        #expect(rest.view.frame == bench.list.frame(for: rest.row))
        #expect(bench.list.stuckHeader == nil && bench.list.stuckVeil.isHidden && !sidebar.edgeFade.holdsTopEdge)

        for y: CGFloat in [400, 2_000, 6_000] {
            _ = bench.frame(to: y)
            let (view, row) = try Self.header(bench)
            let top = Self.top(bench)
            #expect(row.y < top, "scrolled past the header (y \(y))")
            #expect(view === rest.view, "the stuck header is the header's own view: one element for hover, clicks and VoiceOver")
            #expect(abs(view.frame.minY - top) < 0.5, "the header draws at the visible top (y \(y)): \(view.frame.minY) vs \(top)")
            #expect(view.frame.height == row.height && !view.isHidden && view.alphaValue == 1)
            // Over the rows that pass under it, on its veil: the header's band, then the 12 pt fade.
            let veil = bench.list.stuckVeil
            #expect(!veil.isHidden && abs(veil.frame.minY - top) < 0.5)
            #expect(veil.frame.height == row.height + SidebarStuckVeilView.fadeHeight && veil.frame.width == bench.list.bounds.width)
            #expect((view.layer?.zPosition ?? 0) > (veil.layer?.zPosition ?? 0) && (veil.layer?.zPosition ?? 0) > 0)
            let member = try #require(bench.list.displayed.row(at: top + 2), "a member row passes under the header")
            #expect(member.key != row.key)
            if let memberView = bench.list.rowViews[member.key] { #expect((memberView.layer?.zPosition ?? 0) == 0) }
            // A point on it is the header's, not the row under it: hover, clicks and the group card.
            let point = CGPoint(x: bench.list.bounds.midX, y: top + row.height / 2)
            #expect(bench.list.hoverHit(at: point)?.key == .group(Self.group))
            #expect(bench.list.clickHit(at: point)?.key == .group(Self.group))
            #expect(sidebar.edgeFade.holdsTopEdge, "the list's top fade holds off under the stuck header")
        }

        // Back at the top: its own place again, the veil gone.
        _ = bench.frame(to: 0)
        let back = try Self.header(bench)
        #expect(back.view.frame == bench.list.frame(for: back.row))
        #expect(bench.list.stuckHeader == nil && bench.list.stuckVeil.isHidden && !sidebar.edgeFade.holdsTopEdge)
    }

    @Test func theRowAfterTheGroupPushesTheStuckHeaderUp() throws {
        // Groups of eight first (`mixed`): the first group's last member, then the next group's header.
        let bench = SidebarScrollBench(count: 60, height: 400)
        defer { bench.close() }
        let rows = bench.list.displayed.rows
        let header = try #require(bench.list.displayed.row(for: .group(Self.group)))
        let last = try #require(rows.last { $0.group == Self.group })
        // The visible top half a header above the last member's bottom: the header rides up with it.
        _ = bench.frame(to: last.maxY - header.height / 2 - bench.list.stickyTopInset)
        let view = try Self.header(bench).view
        #expect(abs(view.frame.minY - (last.maxY - header.height)) < 0.5,
                "pushed: the header's bottom on the group's last row's bottom (\(view.frame.minY) vs \(last.maxY - header.height))")
        #expect(view.frame.minY < Self.top(bench))
        // Once the last member passed the top, the first group's header lets go.
        _ = bench.frame(to: last.maxY + 1 - bench.list.stickyTopInset)
        #expect(bench.list.stuckHeader?.group != Self.group)
    }

    @Test func collapsingTheStuckGroupLeavesItsHeaderAtItsOwnPlaceAtTheTop() throws {
        // Rows below the group, so the collapsed list still scrolls to the header's place.
        let bench = SidebarScrollBench(count: 600, shape: .openGroupThenLoose(members: 300))
        defer { bench.close() }
        _ = bench.frame(to: 3_000)
        let before = try Self.header(bench)
        let onScreen = before.view.frame.minY - bench.clip.bounds.minY
        #expect(bench.list.stuckHeader?.group == Self.group)

        // A click on the stuck header folds as a click on it at rest does (`toggleCollapse`), through the same fold.
        #expect(bench.model.setGroupCollapsed(Self.group, true))
        bench.drawFrame()
        let after = try Self.header(bench)
        #expect(after.view === before.view)
        #expect(after.row.isCollapsed)
        #expect(abs(after.row.y - Self.top(bench)) < 0.5, "the collapsed header is at its own place, at the visible top")
        #expect(after.view.frame == bench.list.frame(for: after.row))
        #expect(abs(after.view.frame.minY - bench.clip.bounds.minY - onScreen) < 0.5, "the header did not move on screen")
        #expect(bench.list.stuckHeader == nil && bench.list.stuckVeil.isHidden)
    }

    @Test func aRowRevealedUnderTheStuckHeaderComesOutBelowIt() throws {
        let bench = SidebarScrollBench(count: 300, shape: .oneGroup)
        defer { bench.close() }
        _ = bench.frame(to: 2_000)
        let header = try Self.header(bench).row
        let top = Self.top(bench)
        let hidden = try #require(bench.list.displayed.rows.first { $0.y >= top && $0.y < top + header.height && $0.key != header.key })
        let extent = ListViewport<SidebarRowKey>.Item(id: hidden.key, start: hidden.y, length: hidden.height)
        let clear = bench.list.revealClearOfStuckHeader(extent, in: bench.list.displayed)
        #expect(clear.start == hidden.y - header.height && clear.length == hidden.height + header.height)
        // Its own group's header is part of a reveal of the group's first row already: nothing more.
        let first = ListViewport<SidebarRowKey>.Item(id: header.key, start: header.y, length: header.height + 30)
        let same = bench.list.revealClearOfStuckHeader(first, in: bench.list.displayed)
        #expect(same.start == first.start && same.length == first.length)
    }

    @Test func underReduceTransparencyTheVeilIsTheOpaqueSidebarToneWithNoBlur() throws {
        let bench = SidebarScrollBench(count: 300, shape: .oneGroup)
        defer { bench.close() }
        _ = bench.frame(to: 2_000)
        let veil = bench.list.stuckVeil
        defer { ReduceTransparency.shared.override = nil }
        ReduceTransparency.shared.override = false
        veil.updateLayer()
        #expect(!veil.blur.isHidden)
        let glassAlpha = try #require(veil.tone.backgroundColor?.alpha)
        ReduceTransparency.shared.override = true
        veil.updateLayer()
        #expect(veil.blur.isHidden)
        #expect(veil.tone.backgroundColor?.alpha == 1)
        #expect(glassAlpha < 1, "with transparency the tone is the sidebar's at 90%")
    }

    struct Sample {
        var members: Int
        var sticky: Bool
        var frames: Int
        /// Every view in the sidebar's tree after the scroll.
        var views: Int
        var rowViews: Int
        var configuresPerFrame: Double
        var stuckUpdatesPerFrame: Double
        var stuckFrames: Int
        var cpuP50: Double

        var line: String {
            String(format: "members=%d sticky=%@ frames=%d views=%d row_views=%d configures/frame=%.2f stuck_updates/frame=%.2f stuck_frames=%d cpu_ms p50 %.3f",
                   members, sticky ? "on" : "off", frames, views, rowViews, configuresPerFrame, stuckUpdatesPerFrame, stuckFrames, cpuP50)
        }
    }

    /// The same scroll (down 1,800 pt and back, 40 pt a frame, warm-up pass dropped) through one open group of `members`
    /// in a 400 pt sidebar, so a group of 30 scrolls too.
    static func scroll(_ members: Int, sticky: Bool) -> Sample {
        let bench = SidebarScrollBench(count: members, height: 400, shape: .oneGroup)
        defer { bench.close() }
        bench.list.sticksHeaders = sticky
        var stuckFrames = 0
        var frames: [SidebarScrollBench.Frame] = []
        for pass in 0...1 {
            var y: CGFloat = 0
            let bottom = min(bench.maxY, 1_800)
            var down: [SidebarScrollBench.Frame] = []
            while y < bottom { y = min(bottom, y + 40); down.append(bench.frame(to: y)); if pass > 0, bench.list.stuckHeader != nil { stuckFrames += 1 } }
            while y > 0 { y = max(0, y - 40); down.append(bench.frame(to: y)); if pass > 0, bench.list.stuckHeader != nil { stuckFrames += 1 } }
            if pass > 0 { frames = down }
            bench.drain()
        }
        let n = Double(max(frames.count, 1))
        return Sample(members: members, sticky: sticky, frames: frames.count, views: SidebarLongListScaleTests.viewCount(bench.sidebar),
                      rowViews: bench.rowViewsInList,
                      configuresPerFrame: Double(frames.map(\.configures).reduce(0, +)) / n,
                      stuckUpdatesPerFrame: Double(frames.map(\.stuckUpdates).reduce(0, +)) / n, stuckFrames: stuckFrames,
                      cpuP50: SidebarScrollBench.percentile(frames.map(\.cpuMs), 0.5))
    }

    /// The constant-cost rule (Leo 2026-11-04: interaction cost stays constant as workspaces grow): with sticky headers
    /// on, a scroll frame through a group of 3,000 configures, holds and finds the stuck header as one through a group of
    /// 30 does, within 1.2x. Printed with sticky headers off (before) and on (after), from one harness.
    @Test func aScrollThroughAGroupOfThreeThousandCostsWhatOneOfThirtyDoes() {
        var on: [Int: Sample] = [:]
        for sticky in [false, true] {
            for members in [30, 3_000] {
                let sample = Self.scroll(members, sticky: sticky)
                print("SIDEBAR-STICKY \(sticky ? "after" : "before") " + sample.line)
                if sticky { on[members] = sample }
            }
        }
        guard let small = on[30], let large = on[3_000] else { return }
        #expect(small.stuckFrames > 0 && large.stuckFrames > 0, "both scrolls stick the header: \(small.line) / \(large.line)")
        #expect(large.configuresPerFrame <= small.configuresPerFrame * 1.2 + 0.05, "configures/frame grew: \(small.line) -> \(large.line)")
        #expect(Double(large.views) <= Double(small.views) * 1.2, "views grew: \(small.line) -> \(large.line)")
        #expect(Double(large.rowViews) <= Double(small.rowViews) * 1.2 + 1, "row views grew: \(small.line) -> \(large.line)")
        #expect(large.stuckUpdatesPerFrame <= small.stuckUpdatesPerFrame * 1.2, "stuck-header updates/frame grew: \(small.line) -> \(large.line)")
    }
}
