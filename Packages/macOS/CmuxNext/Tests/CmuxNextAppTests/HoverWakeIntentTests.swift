import CmuxNextCompat
@testable import CmuxNextHibernation
import Testing

/// The dwell that turns a hover into a wake (plans/cmux-next/hover-preload-DESIGN.md), on a simulated
/// clock: the timer the gate arms is played back here at its deadlines.
@Suite struct HoverWakeIntentTests {
    /// Plays a pointer path against `HoverWakeIntent` and its one timer, as `HoverWakeGate` runs them.
    struct Pointer {
        var intent = HoverWakeIntent(dwell: .milliseconds(100))
        let start = ContinuousClock.now
        var deadline: ContinuousClock.Instant?
        var intents: [HoverWakeTarget] = []
        var timerFires = 0

        mutating func advance(to time: ContinuousClock.Instant) {
            while let due = deadline, due <= time {
                deadline = nil
                timerFires += 1
                switch intent.fire(at: due) {
                case .idle: break
                case let .rearm(left): deadline = due + left
                case let .intent(target): intents.append(target)
                }
            }
        }

        mutating func move(to target: HoverWakeTarget?, atMs ms: Double) {
            let time = start + .microseconds(Int64(ms * 1000))
            advance(to: time)
            if let delay = intent.note(target, at: time) { deadline = time + delay }
        }

        mutating func rest(untilMs ms: Double) {
            advance(to: start + .microseconds(Int64(ms * 1000)))
        }
    }

    static func row(_ index: Int) -> HoverWakeTarget { .workspace("w\(index)", window: "window") }

    /// (a) A sweep over 200 rows at 120 Hz (a new row every frame) then off the sidebar: no intent, and
    /// the timer fired about once per dwell (off the main thread), not once per row.
    @Test func aSweepOverTwoHundredRowsStartsNoWake() {
        var pointer = Pointer()
        let frame = 1000.0 / 120
        for index in 0..<200 { pointer.move(to: Self.row(index), atMs: Double(index) * frame) }
        pointer.move(to: nil, atMs: 200 * frame)
        pointer.rest(untilMs: 200 * frame + 1000)
        #expect(pointer.intents.isEmpty)
        // One fire per dwell while the sweep lasts (each re-arms for the time left), one when it rounds up,
        // and the last one after the pointer left (it finds nothing resting).
        #expect(pointer.timerFires <= Int((200 * frame / 100).rounded(.up)) + 2)
    }

    /// A sweep that slows to 2 rows per dwell still starts nothing; resting on the last row starts it, once.
    @Test func restingAfterASweepWakesOnlyTheRowItRestsOn() {
        var pointer = Pointer()
        for index in 0..<20 { pointer.move(to: Self.row(index), atMs: Double(index) * 50) }
        pointer.rest(untilMs: 19 * 50 + 99)
        #expect(pointer.intents.isEmpty)
        pointer.rest(untilMs: 19 * 50 + 101)
        #expect(pointer.intents == [Self.row(19)])
        pointer.rest(untilMs: 10_000)
        #expect(pointer.intents == [Self.row(19)], "resting longer repeated the intent")
    }

    /// Leaving within the dwell cancels; a newer target replaces the older one.
    @Test func leavingCancelsAndANewerTargetReplacesTheOlder() {
        var pointer = Pointer()
        pointer.move(to: .tab("a"), atMs: 0)
        pointer.move(to: nil, atMs: 60)
        pointer.rest(untilMs: 500)
        #expect(pointer.intents.isEmpty)

        pointer.move(to: .tab("b"), atMs: 600)
        pointer.move(to: .tab("c"), atMs: 690)
        pointer.rest(untilMs: 1_000)
        #expect(pointer.intents == [.tab("c")])

        // Back on b after leaving: a new stay, a new intent.
        pointer.move(to: .tab("b"), atMs: 1_100)
        pointer.rest(untilMs: 1_300)
        #expect(pointer.intents == [.tab("c"), .tab("b")])
    }

    /// 2 pages, 1 under a memory pressure warning or in Low Power Mode, none at critical; at most 2 restores load.
    @Test func theBudgetShrinksUnderPressureAndLowPower() {
        #expect(HoverWakeBudget(pressure: .normal, lowPower: false).pages == 2)
        #expect(HoverWakeBudget(pressure: .normal, lowPower: true).pages == 1)
        #expect(HoverWakeBudget(pressure: .warning, lowPower: false).pages == 1)
        #expect(HoverWakeBudget(pressure: .critical, lowPower: false).pages == 0)
        let normal = HoverWakeBudget(pressure: .normal, lowPower: false)
        #expect(normal.restores(wanted: 3, loading: 0) == 2)
        #expect(normal.restores(wanted: 3, loading: 1) == 1)
        #expect(normal.restores(wanted: 3, loading: 2) == 0)
        #expect(HoverWakeBudget(pressure: .warning, lowPower: false).restores(wanted: 2, loading: 0) == 1)
    }

    /// What a workspace row's click shows: each pane's selected tab once, in pane order, or the zoomed pane's alone.
    @Test func theShownTabsAreEachPanesSelectionOrTheZoomedPanes() {
        let panes = [HoverWakePanes.Pane(id: "p1", selected: "t1"), .init(id: "p2", selected: nil),
                     .init(id: "p3", selected: "t3"), .init(id: "p4", selected: "t1")]
        #expect(HoverWakePanes(panes, zoomed: nil).shownTabs() == ["t1", "t3"])
        #expect(HoverWakePanes(panes, zoomed: "p3").shownTabs() == ["t3"])
        #expect(HoverWakePanes(panes, zoomed: "gone").shownTabs() == ["t1", "t3"])
        #expect(HoverWakePanes(panes, zoomed: nil).shownTabs(limit: 1) == ["t1"])
    }
}
