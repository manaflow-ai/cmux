import Foundation
import Testing
@testable import CmuxNextBrowser

/// Idle power (msg 2654): a page that changes its title every frame (a timer,
/// a progress counter) cost the app about 89 wakeups/s and 19 mW on cmux14,
/// because each title change re-rendered the browser toolbar and the tab's
/// rows. A page's title reaches its state at most `TitleCoalescer.interval`
/// apart: the first change at once, the latest one at the end of the interval.
@Suite struct TitleCoalescerTests {
    /// Offers `titles` at their times and fires each deadline when it passes;
    /// returns the titles applied to the page state, in order.
    private func run(_ titles: [(Double, String?)], end: Double) -> [String?] {
        var coalescer = TitleCoalescer()
        var applied: [String?] = []
        var deadline: Double?
        func fire(upTo now: Double) {
            if let due = deadline, due <= now {
                deadline = nil
                if let update = coalescer.fire(now: due) { applied.append(update.title) }
            }
        }
        for (time, title) in titles {
            fire(upTo: time)
            switch coalescer.offer(title, now: time) {
            case .apply(let update): applied.append(update.title)
            case .wait(let until): deadline = deadline ?? until
            }
        }
        fire(upTo: end)
        return applied
    }

    @Test func aSingleTitleAppliesAtOnce() {
        var coalescer = TitleCoalescer()
        #expect(coalescer.offer("Inbox", now: 10) == .apply(TitleCoalescer.Update(title: "Inbox")))
    }

    @Test func aTitleEveryFrameAppliesAtMostFourTimesASecond() {
        let frames = (0..<60).map { (Double($0) / 60, Optional("frame \($0)")) }
        let applied = run(frames, end: 2)
        #expect(applied.count <= Int(1 / TitleCoalescer.interval) + 1, "applied \(applied.count) of 60 titles")
        #expect(applied.last == "frame 59", "the latest title was lost")
    }

    @Test func aTitleLongAfterTheLastAppliesAtOnce() {
        var coalescer = TitleCoalescer()
        _ = coalescer.offer("a", now: 0)
        #expect(coalescer.offer("b", now: 5) == .apply(TitleCoalescer.Update(title: "b")))
    }

    /// Another page event (a load start, an address) first applies a waiting
    /// title, so the page state sees the events in their order.
    @Test func flushHandsOverTheWaitingTitleOnce() {
        var coalescer = TitleCoalescer()
        _ = coalescer.offer("a", now: 0)
        _ = coalescer.offer(nil, now: 0.01)
        #expect(coalescer.flush(now: 0.02) == TitleCoalescer.Update(title: nil))
        #expect(coalescer.flush(now: 0.03) == nil)
        #expect(coalescer.fire(now: 0.25) == nil)
    }
}
