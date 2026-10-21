import Foundation
import Testing
@testable import CmuxNextBrowser

/// A stream of pointer moves over a browser toolbar asks the window server once per
/// ``WindowUnderPointerMemo/lifetime`` and window, not on every move.
@Suite struct WindowUnderPointerMemoTests {
    /// A memo and a fake window server that counts its answers.
    private struct Probe {
        var memo = WindowUnderPointerMemo()
        var top: Int
        var asks = 0

        mutating func isTop(_ window: Int, at now: TimeInterval) -> Bool {
            let answer = top
            var asked = 0
            let result = memo.isTop(window, now: now) {
                asked += 1
                return answer
            }
            asks += asked
            return result
        }
    }

    @Test func movesWithinTheLifetimeAskOnce() {
        var probe = Probe(top: 7)
        // 120 Hz moves for just under one lifetime.
        let moves = Int(WindowUnderPointerMemo.lifetime * 120) - 1
        var answers: [Bool] = []
        for move in 0..<moves {
            answers.append(probe.isTop(7, at: 100 + Double(move) / 120))
        }
        #expect(answers.allSatisfy { $0 })
        #expect(probe.asks == 1)
    }

    @Test func anOldAnswerIsAskedAgain() {
        var probe = Probe(top: 7)
        let first = probe.isTop(7, at: 100)
        probe.top = 9
        let young = probe.isTop(7, at: 100 + WindowUnderPointerMemo.lifetime / 2)
        let old = probe.isTop(7, at: 100 + WindowUnderPointerMemo.lifetime)
        #expect(first)
        #expect(young)
        #expect(!old)
        #expect(probe.asks == 2)
    }

    @Test func anotherWindowIsAskedAgain() {
        var probe = Probe(top: 9)
        let seven = probe.isTop(7, at: 100)
        let nine = probe.isTop(9, at: 100.01)
        #expect(!seven)
        #expect(nine)
        #expect(probe.asks == 2)
    }

    @Test func aClockThatWentBackIsAskedAgain() {
        var probe = Probe(top: 7)
        let first = probe.isTop(7, at: 100)
        let earlier = probe.isTop(7, at: 99)
        #expect(first)
        #expect(earlier)
        #expect(probe.asks == 2)
    }
}
