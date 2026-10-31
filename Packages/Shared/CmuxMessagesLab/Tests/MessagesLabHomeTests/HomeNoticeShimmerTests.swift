import AppKit
import Foundation
import Testing
@testable import MessagesLabHome

/// User 2026-10-30 5:03 PM: "i don't like this ui… make it just one line with shimmer text" (over a
/// "›" row, "Running · 4s" and the typing dots). The Chief's status line is one row whose text a
/// light band sweeps across (render server, no per-frame app work); under Reduce Motion it holds
/// still; any other row the cell shows later has no shimmer.
@MainActor @Suite(.serialized) struct HomeNoticeShimmerTests {
    static func row(_ notice: String?, typing: Bool = true) throws -> RowSpec {
        let rows = RowBuilder.rows(HomeTurnStatusTests.state(typing: typing, notice: notice), messages: [], now: HomeTurnStatusTests.t0,
                                   width: 529, scale: 2)
        return try #require(rows.first { $0.key == (notice == nil ? "typing" : "notice") })
    }

    @Test func theStatusLineShimmers() throws {
        MessagesLabHomeView.reduceMotionOverride = false
        defer { MessagesLabHomeView.reduceMotionOverride = nil }
        let cell = RowCell(frame: CGRect(x: 0, y: 0, width: 529, height: 40))
        cell.configure(try Self.row("Running · 4s"))
        let shimmer = try #require(cell.noticeShimmer)
        #expect(cell.bitmap.mask === shimmer.mask)
        #expect(shimmer.isRunning)
        let begin = try #require(shimmer.band.animation(forKey: HomeNoticeShimmer.animationKey)).beginTime
        // The next second of the same line: the sweep goes on where it was, it does not start over.
        cell.configure(try Self.row("Running · 5s"))
        #expect(cell.noticeShimmer === shimmer)
        #expect(shimmer.band.animation(forKey: HomeNoticeShimmer.animationKey)?.beginTime == begin)
    }

    @Test func reduceMotionHoldsTheLineStill() throws {
        MessagesLabHomeView.reduceMotionOverride = true
        defer { MessagesLabHomeView.reduceMotionOverride = nil }
        let cell = RowCell(frame: CGRect(x: 0, y: 0, width: 529, height: 40))
        cell.configure(try Self.row("Running · 4s"))
        let shimmer = try #require(cell.noticeShimmer)
        #expect(cell.bitmap.mask === shimmer.mask)
        #expect(!shimmer.isRunning)
        // Reduce Motion turned off while the line shows: the sweep starts.
        MessagesLabHomeView.reduceMotionOverride = false
        cell.applyReduceMotion()
        #expect(shimmer.isRunning)
    }

    @Test func anotherRowHasNoShimmer() throws {
        MessagesLabHomeView.reduceMotionOverride = false
        defer { MessagesLabHomeView.reduceMotionOverride = nil }
        let cell = RowCell(frame: CGRect(x: 0, y: 0, width: 529, height: 40))
        cell.configure(try Self.row("Running · 4s"))
        #expect(cell.bitmap.mask != nil)
        cell.prepareForReuse()
        cell.configure(try Self.row(nil))
        #expect(cell.bitmap.mask == nil)
        #expect(cell.noticeShimmer?.isRunning != true)
    }
}
