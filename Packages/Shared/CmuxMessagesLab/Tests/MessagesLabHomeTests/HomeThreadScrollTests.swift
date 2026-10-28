import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Scrolling in Home's thread and reply view (Lawrence 2026-10-28, cmux-next nightly 4062224: "i cant
/// scroll up/down after clicking into like the thread ui"). A reply view on a long message showed the
/// message centered in the pane, taller than the pane: its top was above the header and its bottom
/// was under the field, and a wheel or trackpad scroll moved only the dimmed transcript under it.
/// The real view over a real `HomeStore` (`HomeChatRig`); the wheel goes through the transcript
/// scroll view's route (`TranscriptScrollView.routeThreadWheel`), the path its event monitor takes.
@MainActor @Suite(.serialized) struct HomeThreadScrollTests {
    static let lines = 60

    private func longText() -> String {
        (1...Self.lines).map { "\(HomeChatRig.tag) line \($0) of a long report Hgjpqy" }.joined(separator: "\n")
    }

    /// A phased trackpad scroll event of `dy` points (positive: the content moves down, toward the top).
    private func wheel(_ dy: CGFloat, phase: Int64 = 2) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return try #require(NSEvent(cgEvent: cg))
    }

    /// The open thread view's rows, top to bottom, in the window view's coordinates.
    private func threadFrames(_ demo: MessagesWindowView) -> [CGRect] {
        demo.threadViews.map { $0.frame.insetBy(dx: 0, dy: RowDraw.margin) }
    }

    /// The long message sent, then Reply… on it, the caret in the reply field (the user's "clicking into" it).
    private func openLongReply() async throws -> (HomeChatRig, MessagesWindowView) {
        let r = try await HomeChatRig(history: 4)
        await r.send(longText())
        for _ in 0..<4 { r.frame() }
        try #require(r.view.debugReplyNewest(mine: true) != nil, "Reply… opened no view")
        for _ in 0..<4 { r.frame() }
        let demo = try #require(r.view.controller.demo)
        r.window.makeFirstResponder(demo.compose.textView.view)
        try #require(demo.threadOpen)
        try #require(!demo.threadViews.isEmpty)
        return (r, demo)
    }

    @Test func aLongReplyViewEndsAboveTheFieldAndScrollsToItsTop() async throws {
        let (r, demo) = try await openLongReply()
        defer { r.stop() }
        let top = Fixture.headerHeight, bottom = demo.fieldTop
        let opened = threadFrames(demo)
        let first = try #require(opened.first), last = try #require(opened.last)
        try #require(last.maxY - first.minY > bottom - top, "the message is taller than the pane (else nothing to scroll)")
        #expect(last.maxY <= bottom + 0.5, "the newest row ends above the reply field (was \(last.maxY), field top \(bottom))")

        // Scroll toward the top, a trackpad stream; the rows follow and stop with the root's top under the header.
        let scroll = r.view.controller.host.scrollView
        var moved = false
        for _ in 0..<200 { if scroll.routeThreadWheel(try wheel(40)) { moved = true } }
        r.frame()
        #expect(moved, "the wheel went to the thread view")
        let up = try #require(threadFrames(demo).first)
        #expect(up.minY >= top - 0.5, "the root's top shows below the header (was \(up.minY), header bottom \(top))")
        #expect(up.minY <= top + 24, "the scroll stops at the root's top (was \(up.minY))")

        // And back down to the newest row.
        for _ in 0..<200 { _ = scroll.routeThreadWheel(try wheel(-40)) }
        r.frame()
        let down = try #require(threadFrames(demo).last)
        #expect(abs(down.maxY - last.maxY) < 0.5, "scrolling down ends where the view opened")
        #expect(demo.threadOpen, "scrolling keeps the view open")
    }

    @Test func aShortThreadStaysCenteredAndLeavesTheWheelAlone() async throws {
        let r = try await HomeChatRig(history: 4)
        defer { r.stop() }
        await r.send("\(HomeChatRig.tag) a short one")
        for _ in 0..<4 { r.frame() }
        try #require(r.view.debugReplyNewest(mine: true) != nil)
        for _ in 0..<4 { r.frame() }
        let demo = try #require(r.view.controller.demo)
        let before = threadFrames(demo)
        let scroll = r.view.controller.host.scrollView
        #expect(scroll.routeThreadWheel(try wheel(40)), "the dimmed transcript under an open view never scrolls")
        #expect(threadFrames(demo) == before, "a thread that fits does not move")
    }

    @Test func withNoThreadOpenTheTranscriptTakesTheWheel() async throws {
        let r = try await HomeChatRig(history: 4)
        defer { r.stop() }
        r.frame()
        #expect(!r.view.controller.host.scrollView.routeThreadWheel(try wheel(40)))
    }
}
