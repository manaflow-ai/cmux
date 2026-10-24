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
        // No pane emptied: every press closes.
        #expect(!aim.aimsAtEmptiedPane(key(1), focused: "b"))
        aim.paneEmptied("b", by: key(10))
        // The focus has not left `b`: the press acts on `b` as on any pane.
        #expect(!aim.aimsAtEmptiedPane(key(10.001), focused: "b"))
        let move = aim.paneMoved(from: "b", to: "a")
        // Moved, not yet presented: aimed at `b`.
        #expect(aim.aimsAtEmptiedPane(key(10.002), focused: "a"))
        aim.presented(move, at: 10.020)
        // Made before the frame was presented: still aimed at `b`.
        #expect(aim.aimsAtEmptiedPane(key(10.010), focused: "a"))
        // A repeat of the held key that emptied `b`, after the frame: the same press.
        #expect(aim.aimsAtEmptiedPane(key(10.5, repeat: true), focused: "a"))
        // A fresh press after the frame: closes in `a`; the hold it starts closes in `a` too.
        #expect(!aim.aimsAtEmptiedPane(key(10.6), focused: "a"))
        #expect(!aim.aimsAtEmptiedPane(key(10.7, repeat: true), focused: "a"))
    }

    /// Pure: a close emptied by a click (no held key), and a focus the person moved since, aim nowhere else.
    @Test func aPressAfterThePersonMovedTheFocusIsTheirs() {
        var aim = PaneCloseAim()
        aim.paneEmptied("b", by: .init(time: 10, isKey: false, isRepeat: false))
        let move = aim.paneMoved(from: "b", to: "a")
        // A stale stamp for an older move changes nothing.
        aim.presented(move &- 1, at: 10.001)
        #expect(aim.move?.presentedAt == nil)
        // The person clicked pane `c` before the frame showed `a`: their next press is theirs.
        _ = aim.paneMoved(from: "a", to: "c")
        #expect(!aim.aimsAtEmptiedPane(.init(time: 10.002, isKey: true, isRepeat: false), focused: "c"))
        #expect(aim.emptied == nil)
    }
}
