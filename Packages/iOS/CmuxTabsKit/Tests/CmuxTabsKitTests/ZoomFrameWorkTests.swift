@testable import CmuxTabsKit
import Testing
#if os(iOS)
import SwiftUI
#endif

/// The tab grid does not re-run on a zoom frame (Leo, 2026-11-25: "the
/// transitioning into and out of the iOS grid is still slow"). The screen
/// re-runs on every frame of the page <-> grid zoom to place the zooming
/// page; the grid and its cards re-ran with it, work in proportion to the
/// tabs on every frame. The grid now sits behind a gate keyed on what it lays
/// out, and the zoom's progress reaches only the leaf effects that draw it.
struct ZoomFrameWorkTests {
    @Test func zoomWorkCountsEachViewAndResets() {
        var work = ZoomWork()
        work.note(.screen)
        work.note(.screen)
        work.note(.grid)
        for _ in 0 ..< 5 { work.note(.card) }
        #expect(work.counts == ZoomWork.Counts(screen: 2, grid: 1, cards: 5))
        work.reset()
        #expect(work.counts == ZoomWork.Counts())
    }

    @Test func frameLogSpansTheZoomOnTheMediaClock() throws {
        var log = ZoomFrameLog()
        log.begin(at: 100, toOverview: false)
        log.frame(at: 100.01)
        log.frame(at: 100.30)
        let summary = log.end(maxFPS: 120)
        let s = try #require(summary)
        #expect(abs(s.startMs - 100_000) < 0.01 && abs(s.endMs - 100_300) < 0.01)
        #expect(s.work == nil)
    }

    #if os(iOS)
    @MainActor
    @Test func awakeGateWithTheSameInputsHoldsItsContent() {
        let a = DormantGate(dormant: false, key: GateKey(Inputs(cards: 27, hidden: "t-zsh"))) { Color.clear }
        let sameInputs = DormantGate(dormant: false, key: GateKey(Inputs(cards: 27, hidden: "t-zsh"))) { Color.clear }
        let otherHidden = DormantGate(dormant: false, key: GateKey(Inputs(cards: 27, hidden: nil))) { Color.clear }
        let unkeyed = DormantGate(dormant: false) { Color.clear }
        let asleep = DormantGate(dormant: true, key: GateKey(Inputs(cards: 27, hidden: "t-zsh"))) { Color.clear }
        // A zoom frame: the screen re-runs with the same inputs, the grid does not.
        #expect(a == sameInputs)
        #expect(a != otherHidden)
        // No key: every update of the parent passes on, as before.
        #expect(unkeyed != unkeyed)
        // Waking compares unequal, so the grid gets the current values at once.
        #expect(a != asleep && asleep == asleep)
    }

    @MainActor
    @Test func gateKeysOfDifferentTypesDiffer() {
        #expect(GateKey(1) == GateKey(1))
        #expect(GateKey(1) != GateKey("1"))
    }

    private struct Inputs: Equatable, Sendable {
        var cards: Int
        var hidden: String?
    }
    #endif
}
