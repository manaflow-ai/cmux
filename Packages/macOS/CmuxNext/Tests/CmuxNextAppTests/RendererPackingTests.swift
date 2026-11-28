import CmuxNextHibernation
import Testing

/// Goal memory-per-chat: the visible chat left alone in a second renderer after a burst of opens is built again
/// in the oldest renderer once that has room, so the second renderer exits (bench 6b4a829c).
@Suite struct RendererPackingTests {
    private let site = "cmux-page://cmux.agent"

    private func page(_ browser: Int32, in renderer: Int32, movable: Bool = false, site: String? = nil) -> RendererPacking.Page {
        RendererPacking.Page(browser: browser, renderer: renderer, site: site ?? self.site, movable: movable)
    }

    @Test func movesTheVisibleChatAloneInALaterRendererWhenTheOldestHasRoom() {
        // The launch's 3 pages and two chats in renderer 1; the visible chat alone in renderer 2.
        let pages = (1...5).map { page($0, in: 1) } + [page(9, in: 2, movable: true)]
        #expect(RendererPacking.nextMove(pages, cap: 8) == 9)
    }

    @Test func keepsItWhenTheOldestIsFull() {
        let pages = (1...8).map { page($0, in: 1) } + [page(9, in: 2, movable: true)]
        #expect(RendererPacking.nextMove(pages, cap: 8) == nil)
    }

    @Test func keepsARendererThatAPageWhichCannotMoveHolds() {
        // A hidden or busy chat beside it would keep renderer 2 alive: the move buys nothing.
        let pages = [page(1, in: 1), page(8, in: 2), page(9, in: 2, movable: true)]
        #expect(RendererPacking.nextMove(pages, cap: 8) == nil)
    }

    @Test func emptiesARendererOfSeveralMovablePagesOnlyWhenAllFit() {
        let two = [page(8, in: 2, movable: true), page(9, in: 2, movable: true)]
        #expect(RendererPacking.nextMove((1...6).map { page($0, in: 1) } + two, cap: 8) == 8)
        #expect(RendererPacking.nextMove((1...7).map { page($0, in: 1) } + two, cap: 8) == nil)
    }

    @Test func onlyAnOlderRendererOfTheSameSiteCounts() {
        let pages = [page(1, in: 1, site: "cmux-page://cmux.settings"), page(9, in: 2, movable: true)]
        #expect(RendererPacking.nextMove(pages, cap: 8) == nil)
        // A newer renderer's room never counts: the fork picks the oldest with room.
        #expect(RendererPacking.nextMove([page(9, in: 2, movable: true), page(10, in: 3)], cap: 8) == nil)
    }

    @Test func theNewestRendererGoesFirst() {
        let pages = [page(1, in: 1), page(5, in: 2, movable: true), page(9, in: 3, movable: true)]
        #expect(RendererPacking.nextMove(pages, cap: 8) == 9)
    }

    @Test func theOldestRendererNeverMoves() {
        #expect(RendererPacking.nextMove([page(1, in: 1, movable: true)], cap: 8) == nil)
        #expect(RendererPacking.nextMove([page(9, in: 2, movable: true)], cap: 0) == nil)
    }
}
