import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-15: "it should be instant even under load". A workspace that appears (new, or switched to cold) shows
/// its content in the first frame that shows it, and the old one stays until then. A pane's tab switch already waits
/// for a page that has not painted (`TabSwitchNoBlankFrameTests`); the window's workspace swap waited only for a
/// resize, so a workspace whose New Tab page or chat had not painted showed a clear pane or a loading cover in place
/// of the outgoing workspace, for as long as the page took (longer under load). Runs a real window root.
@MainActor @Suite(.serialized, .closesItsWindows) struct WorkspaceSwitchNoBlankFrameTests {
    /// A page that draws nothing until it paints, as an agent or New Tab page does.
    final class UnpaintedPage: NSView, PaneFirstPaintGated {
        private var painted = false
        private var waiting: [() -> Void] = []
        var awaitsFirstPaint: Bool { !painted }
        func whenFirstPainted(_ body: @escaping () -> Void) {
            if painted { body() } else { waiting.append(body) }
        }

        func paint() {
            painted = true
            let callbacks = waiting
            waiting = []
            callbacks.forEach { $0() }
        }
    }

    @Test func aNewWorkspaceWhosePageHasNotPaintedKeepsTheOldOneUntilItPaints() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let page = UnpaintedPage()
        let new = WorkspaceSwitchRedrawHoldTests.workspace(page)
        root.show(new)
        root.layoutSubtreeIfNeeded()
        #expect(new.alphaValue == 0, "the new workspace showed before its page painted: a clear pane in its first frame")
        #expect(!old.isHidden && old.alphaValue == 1, "the old workspace left before the new one had a frame")
        page.paint()
        #expect(new.alphaValue == 1, "the new workspace stayed unseen after its page painted")
        #expect(old.isHidden, "the old workspace stayed after the new one showed")
    }

    @Test func aParkedWorkspaceWhosePageHasNotPaintedKeepsTheShownOneUntilItPaints() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let page = UnpaintedPage()
        let cold = WorkspaceSwitchRedrawHoldTests.workspace(page)
        WorkspaceSwitchRedrawHoldTests.show(cold, in: root) // the window's first: nothing to keep
        let shown = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(shown, in: root)
        #expect(cold.isHidden)
        root.show(cold)
        #expect(cold.alphaValue == 0, "a switch to a workspace whose page has not painted showed it clear")
        #expect(!shown.isHidden, "the shown workspace left before the one switched to had a frame")
        page.paint()
        #expect(cold.alphaValue == 1)
        #expect(shown.isHidden)
    }

    @Test func rapidSwitchesThroughUnpaintedWorkspacesKeepTheLastShownOne() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let first = UnpaintedPage(), second = UnpaintedPage()
        let a = WorkspaceSwitchRedrawHoldTests.workspace(first), b = WorkspaceSwitchRedrawHoldTests.workspace(second)
        root.show(a)
        root.show(b)
        #expect(!old.isHidden && old.alphaValue == 1, "a second switch before the first workspace painted went blank")
        #expect(b.alphaValue == 0)
        #expect(a.isHidden || a.alphaValue == 0, "the workspace passed over showed")
        second.paint()
        #expect(b.alphaValue == 1)
        #expect(old.isHidden)
    }

    /// Fifty quick Cmd-Ns (`RapidWorkspaceCreateTests`): a held workspace is laid out by the window's own pass, not in the
    /// press's turn, so one the next press passes over before that pass costs no layout (worst press-to-row 424 ms with a
    /// layout per press, cmux#44329).
    @Test func aHeldWorkspaceIsNotLaidOutInThePresssTurn() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let first = UnpaintedPage(), second = UnpaintedPage()
        let a = WorkspaceSwitchRedrawHoldTests.workspace(first), b = WorkspaceSwitchRedrawHoldTests.workspace(second)
        root.show(a)
        #expect(a.needsLayout, "the held workspace was laid out in the press's turn")
        root.show(b)
        #expect(a.isHidden && a.needsLayout, "the workspace passed over was laid out")
        #expect(!old.isHidden && old.alphaValue == 1 && b.alphaValue == 0)
        root.layoutSubtreeIfNeeded()
        #expect(!b.needsLayout, "the window's pass did not lay out the held workspace")
        second.paint()
        #expect(b.alphaValue == 1 && old.isHidden)
    }

    /// A page its own pane keeps unseen (its tab-switch hold) is not the workspace's to wait for: the pane shows what it kept.
    @Test func aPageItsPaneAlreadyHoldsDoesNotHoldTheSwitch() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let page = UnpaintedPage()
        page.alphaValue = 0
        let new = WorkspaceSwitchRedrawHoldTests.workspace(page)
        root.show(new)
        #expect(new.alphaValue == 1)
        #expect(old.isHidden)
    }

    /// Cmd-N's reserved view was pre-rendered off screen in the window before the key (`CmdNPrebuiltWorkspaceViewTests`):
    /// the key shows it at once, as designed, even if its New Tab page has not reported a paint.
    @Test func cmdNsReservedViewShowsAtOnce() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let reserved = WorkspaceSwitchRedrawHoldTests.workspace(UnpaintedPage())
        reserved.setParked(true)
        reserved.alphaValue = 0
        root.contentHost.addSubview(reserved)
        root.show(reserved)
        #expect(reserved.alphaValue == 1, "Cmd-N's pre-rendered view waited for its page")
        #expect(old.isHidden)
    }

    @Test func aWorkspaceWhosePagesPaintedShowsAtOnce() {
        let (window, root) = WorkspaceSwitchRedrawHoldTests.root()
        defer { window.close() }
        let old = WorkspaceSwitchRedrawHoldTests.workspace(NSView())
        WorkspaceSwitchRedrawHoldTests.show(old, in: root)
        let page = UnpaintedPage()
        page.paint()
        let new = WorkspaceSwitchRedrawHoldTests.workspace(page)
        root.show(new)
        #expect(new.alphaValue == 1, "a workspace whose page painted waited")
        #expect(old.isHidden)
    }
}
