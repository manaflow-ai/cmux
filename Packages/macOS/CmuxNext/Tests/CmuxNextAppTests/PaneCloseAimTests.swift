import CmuxNextFocus
import Foundation
import Testing

/// ``PaneCloseAim``: a Close Tab press is aimed at the pane that was on screen when it was made
/// (Leo 2026-10-21, Lawrence 2026-10-23). Pure; the end-to-end cases are in `CloseTabKeepsPaneTests`.
@MainActor @Suite
struct PaneCloseAimTests {
    /// Pure: the pane a press is aimed at after a close emptied pane `b` and the focus moved to `a`
    /// (``PaneCloseAim``): before the frame showing `a` was presented, a press is aimed at `b`; a
    /// repeat of the held key that emptied `b` is too; a fresh press after that frame closes in `a`.
    @Test func aPressIsAimedAtThePaneOnScreenWhenItWasMade() {
        func key(_ time: TimeInterval, repeat isRepeat: Bool = false) -> PaneCloseAim.Press {
            .init(time: time, isKey: true, isRepeat: isRepeat)
        }
        var aim = PaneCloseAim()
        func aims(_ press: PaneCloseAim.Press, _ focused: String) -> Bool { aim.aimsAtEmptiedPane(press, focused: focused) }
        // No pane emptied: every press closes.
        #expect(!aims(key(1), "b"))
        aim.paneEmptied("b", by: key(10))
        // The focus has not left `b`: the press acts on `b` as on any pane.
        #expect(!aims(key(10.001), "b"))
        let move = aim.paneMoved(from: "b", to: "a")
        // Moved, not yet presented: aimed at `b`.
        #expect(aims(key(10.002), "a"))
        aim.presented(move, at: 10.020)
        // Made before the frame was presented: still aimed at `b`.
        #expect(aims(key(10.010), "a"))
        // A repeat of the held key that emptied `b`, after the frame: the same press.
        #expect(aims(key(10.5, repeat: true), "a"))
        // A fresh press after the frame: closes in `a`; the hold it starts closes in `a` too.
        #expect(!aims(key(10.6), "a"))
        #expect(!aims(key(10.7, repeat: true), "a"))
    }

    /// Pure: a close emptied by a click (no held key), and a focus the person moved since, aim nowhere else.
    @Test func aPressAfterThePersonMovedTheFocusIsTheirs() {
        var aim = PaneCloseAim()
        func aims(_ press: PaneCloseAim.Press, _ focused: String) -> Bool { aim.aimsAtEmptiedPane(press, focused: focused) }
        aim.paneEmptied("b", by: .init(time: 10, isKey: false, isRepeat: false))
        let move = aim.paneMoved(from: "b", to: "a")
        // A stale stamp for an older move changes nothing.
        aim.presented(move &- 1, at: 10.001)
        #expect(aim.move?.presentedAt == nil)
        // The person clicked pane `c` before the frame showed `a`: their next press is theirs.
        _ = aim.paneMoved(from: "a", to: "c")
        #expect(!aims(.init(time: 10.002, isKey: true, isRepeat: false), "c"))
        #expect(aim.emptied == nil)
    }

    /// Review 2 (2026-10-24): after a close emptied `b` and the focus went to `a`, a Cmd-D moves the
    /// focus to the new pane `c` the person made: every later press is theirs, however quick (Cmd-D,
    /// Cmd-Shift-D, Cmd-W six times at 40 ms closes six times).
    @Test func aNewPaneThePersonMadeEndsTheAim() {
        var aim = PaneCloseAim()
        func aims(_ press: PaneCloseAim.Press, _ focused: String) -> Bool { aim.aimsAtEmptiedPane(press, focused: focused) }
        func key(_ time: Double) -> PaneCloseAim.Press { .init(time: time, isKey: true, isRepeat: false) }
        aim.paneEmptied("b", by: key(10))
        aim.presented(aim.paneMoved(from: "b", to: "a"), at: 10.02)
        _ = aim.paneMoved(from: "a", to: "c")
        var closes = 0
        for press in 0..<6 where !aims(key(10.04 + Double(press) * 0.04), "c") { closes += 1 }
        #expect(closes == 6)
    }
}
