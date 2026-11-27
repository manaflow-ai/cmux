import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import CmuxNextWakeups
import Testing

/// `whenSettled` work asked for during a layout motion (a divider drag moves its panes on every display frame, and each
/// moved pane asks again: the New Tab spare's `paneLayoutDidChange`) re-armed its timer on every call: a Task cancelled
/// and another created per moved pane per frame, about 0.14 ms of each sampled divider step (release-resize bp-off-2,
/// 2026-11-26). The work cannot run before the layout is still, so the settle counts from the motion's landing: a call
/// during the motion only replaces the waiting work, and the landing arms the timer once.
@MainActor
@Suite(.closesItsWindows)
struct SettledWorkInMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// A window whose live resize the test sets (`NSWindow.inLiveResize` is true only while a person drags an edge).
    final class LiveResizeWindow: NSWindow {
        var isLive = false
        override var inLiveResize: Bool { isLive }
    }

    private func root() -> (LayoutRootView, LiveResizeWindow) {
        let columns = (1...2).map { LayoutColumn(id: ColumnID("c\($0)"), width: 0.5, root: .leaf(PaneID("p\($0)"))) }
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: Panes())
        let window = LiveResizeWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        return (root, window)
    }

    @Test func callsDuringAMotionArmTheSettleOnceWhenItLands() {
        let (root, window) = root()
        defer { window.closeAfterTest() }
        let queue = FrameBatchQueue(owner: "SettledWorkInMotionTests")
        root.setLayoutInMotion(true)
        var ran: [Int] = []
        for call in 0..<40 { root.whenSettled("SettledWorkInMotionTests.fit", after: .seconds(30), on: queue) { ran.append(call) } }
        #expect(root.settlingWork["SettledWorkInMotionTests.fit"]?.timer.isScheduled == false,
                "a call in the motion armed the settle timer (the work cannot run before the landing)")
        root.setLayoutInMotion(false)
        #expect(root.settlingWork["SettledWorkInMotionTests.fit"]?.timer.isScheduled == true, "the landing did not arm the settle")
        #expect(ran.isEmpty, "the work ran before its settle")
    }

    @Test func aCallWhileStillArmsTheSettleAtOnce() {
        let (root, window) = root()
        defer { window.closeAfterTest() }
        let queue = FrameBatchQueue(owner: "SettledWorkInMotionTests")
        root.whenSettled("SettledWorkInMotionTests.still", after: .seconds(30), on: queue) {}
        #expect(root.settlingWork["SettledWorkInMotionTests.still"]?.timer.isScheduled == true)
    }

    /// The motion's last request is the one that runs: the waiting work is replaced, not added to.
    @Test func theLastRequestOfAMotionIsTheWorkThatWaits() {
        let (root, window) = root()
        defer { window.closeAfterTest() }
        let queue = FrameBatchQueue(owner: "SettledWorkInMotionTests")
        root.setLayoutInMotion(true)
        var ran: [Int] = []
        for call in 0..<3 { root.whenSettled("SettledWorkInMotionTests.last", after: .seconds(30), on: queue) { ran.append(call) } }
        root.setLayoutInMotion(false)
        root.settlingWork["SettledWorkInMotionTests.last"]?.work()
        #expect(ran == [2])
    }

    /// A window's live resize is not a layout motion: nothing at its end reliably arms a held settle (AppKit can still
    /// report the resize in `viewDidEndLiveResize`, the only call at its end). A call during it arms its timer, as
    /// before, so the New Tab spare's fit still runs after a window resize (PR 59620 review).
    @Test func aCallDuringAWindowLiveResizeArmsItsSettle() {
        let (root, window) = root()
        defer { window.closeAfterTest() }
        let queue = FrameBatchQueue(owner: "SettledWorkInMotionTests")
        window.isLive = true
        for _ in 0..<3 { root.whenSettled("SettledWorkInMotionTests.live", after: .seconds(30), on: queue) {} }
        // The resize ends while the window still reports it.
        root.viewDidEndLiveResize()
        #expect(root.settlingWork["SettledWorkInMotionTests.live"]?.timer.isScheduled == true,
                "a settle asked for during a window's live resize never armed")
    }
}
