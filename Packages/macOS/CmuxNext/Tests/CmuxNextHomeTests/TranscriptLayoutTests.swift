@testable import CmuxNextHome
import CoreGraphics
import Foundation
import Testing

struct TranscriptLayoutTests {
    private func rebuilt(_ window: TranscriptWindow, _ context: RowContext) -> TranscriptLayout {
        var layout = TranscriptLayout()
        layout.rebuild(window, context: context)
        return layout
    }

    @Test func topsArePrefixSumsOfGapsAndHeights() {
        let context = HomeFixture.context()
        let layout = rebuilt(HomeFixture.window(1...300), context)
        var y = context.geometry.topPadding
        for (row, top) in zip(layout.rows, layout.tops) {
            y += row.gapBefore
            #expect(top == y)
            y += row.height
        }
        #expect(layout.totalHeight == y)
        #expect(layout.messageStarts.count == 300)
    }

    @Test func incrementalPrependMatchesFullRebuild() {
        let context = HomeFixture.context()
        var window = HomeFixture.window(201...400, newest: 400)
        var layout = rebuilt(window, context)
        let change = window.prepend(HomeFixture.messages(101...200))
        #expect(change == .prepend(100))
        layout.apply(change, window: window, context: context)
        #expect(layout.snapshot == rebuilt(window, context).snapshot)
    }

    @Test func incrementalEvictionsMatchFullRebuild() {
        let context = HomeFixture.context()
        var window = HomeFixture.window(1...500, newest: 900)
        var layout = rebuilt(window, context)
        var change = window.evict(top: 120, bottom: 0)
        #expect(change == .evictTop(120))
        layout.apply(change, window: window, context: context)
        #expect(layout.snapshot == rebuilt(window, context).snapshot)
        change = window.evict(top: 0, bottom: 80)
        #expect(change == .evictBottom(80))
        layout.apply(change, window: window, context: context)
        #expect(layout.snapshot == rebuilt(window, context).snapshot)
        #expect(window.firstSeq == 121 && window.lastSeq == 420)
    }

    @Test func appendAndUpdateMatchFullRebuild() {
        let context = HomeFixture.context(readThrough: 300)
        var window = HomeFixture.window(1...300)
        var layout = rebuilt(window, context)
        var change = window.appendConfirmed(HomeFixture.messages(301...304))
        layout.apply(change, window: window, context: context)
        #expect(layout.snapshot == rebuilt(window, context).snapshot)
        var edited = window[150]
        edited.reactions = [HomeReaction(authorID: HomeFixture.agent, kind: "love")]
        change = window.update(edited)
        #expect(change == .touched([150]))
        layout.apply(change, window: window, context: context)
        #expect(layout.snapshot == rebuilt(window, context).snapshot)
    }

    /// The anchor row keeps its screen y when older messages join above it
    /// or the top is evicted (the view's own scroll math).
    @Test func anchorKeepsScreenPositionAcrossPrependAndEvict() throws {
        let view = TranscriptView(frame: CGRect(x: 0, y: 0, width: 640, height: 800))
        view.geometry = HomeFixture.geometry
        view.history = HomeFixture.window(201...400, newest: 900, oldest: 1)
        view.rowLayout.rebuild(view.history, context: view.context())
        let key = view.rowLayout.rows[120].key
        view.anchor = TranscriptAnchor(pinned: false, key: key, top: 333)
        func screenY() throws -> CGFloat {
            let found = view.rowLayout.rowIndex(of: key)
            let index = try #require(found)
            return view.contentBase() + view.rowLayout.tops[index]
        }
        #expect(try screenY() == 333)
        let before = view.rowLayout.tops[120]
        view.rowLayout.apply(view.history.prepend(HomeFixture.messages(101...200)), window: view.history,
                             context: view.context())
        let movedIndex = view.rowLayout.rowIndex(of: key)
        let moved = try #require(movedIndex)
        #expect(moved > 120)
        #expect(view.rowLayout.tops[moved] > before)
        #expect(try screenY() == 333)
        view.rowLayout.apply(view.history.evict(top: 50, bottom: 0), window: view.history, context: view.context())
        #expect(try screenY() == 333)
    }

    @Test func reflowMovesOnlyX() {
        let context = HomeFixture.context()
        var layout = rebuilt(HomeFixture.window(1...60), context)
        let heights = layout.rows.map(\.height), tops = layout.tops
        var wider = context.geometry
        wider.width += 40
        layout.reflow(to: wider)
        #expect(layout.rows.map(\.height) == heights)
        #expect(layout.tops == tops)
        for row in layout.rows where row.isOutgoing && row.isBubbleLike {
            #expect(row.x + row.width == wider.width - wider.sideMargin)
        }
    }

    @Test func typingRowIsLastAndLeavesCleanly() {
        let window = HomeFixture.window(1...20)
        var layout = rebuilt(window, HomeFixture.context())
        let plain = layout.snapshot
        _ = layout.setTyping(window, context: HomeFixture.context(typing: true))
        #expect(layout.rows.last?.key == "typing")
        _ = layout.setTyping(window, context: HomeFixture.context(typing: false))
        #expect(layout.snapshot == plain)
    }
}
