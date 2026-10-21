import Foundation
import Testing
@testable import CmuxNextBrowser

/// A stream of pointer moves over a browser toolbar asks the window server once per
/// ``WindowUnderPointerMemo/lifetime`` and window, not on every move.
@Suite struct WindowUnderPointerMemoTests {
    @Test func movesWithinTheLifetimeAskOnce() {
        var memo = WindowUnderPointerMemo()
        var asks = 0
        let ask = { () -> Int in asks += 1; return 7 }
        // 120 Hz moves for just under one lifetime.
        let moves = Int(WindowUnderPointerMemo.lifetime * 120) - 1
        for move in 0..<moves {
            #expect(memo.isTop(7, now: 100 + Double(move) / 120, ask: ask))
        }
        #expect(asks == 1)
    }

    @Test func anOldAnswerIsAskedAgain() {
        var memo = WindowUnderPointerMemo()
        var top = 7
        var asks = 0
        let ask = { () -> Int in asks += 1; return top }
        #expect(memo.isTop(7, now: 100, ask: ask))
        top = 9
        #expect(memo.isTop(7, now: 100 + WindowUnderPointerMemo.lifetime / 2, ask: ask))
        #expect(!memo.isTop(7, now: 100 + WindowUnderPointerMemo.lifetime, ask: ask))
        #expect(asks == 2)
    }

    @Test func anotherWindowIsAskedAgain() {
        var memo = WindowUnderPointerMemo()
        var asks = 0
        let ask = { () -> Int in asks += 1; return 9 }
        #expect(!memo.isTop(7, now: 100, ask: ask))
        #expect(memo.isTop(9, now: 100.01, ask: ask))
        #expect(asks == 2)
    }

    @Test func aClockThatWentBackIsAskedAgain() {
        var memo = WindowUnderPointerMemo()
        var asks = 0
        let ask = { () -> Int in asks += 1; return 7 }
        #expect(memo.isTop(7, now: 100, ask: ask))
        #expect(memo.isTop(7, now: 99, ask: ask))
        #expect(asks == 2)
    }
}
