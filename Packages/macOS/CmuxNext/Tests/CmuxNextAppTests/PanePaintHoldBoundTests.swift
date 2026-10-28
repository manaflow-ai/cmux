import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextInput
@testable import CmuxNextPages
@testable import CmuxNextTabs
import CmuxNextWakeups
import Testing

/// A switch to a tab or a workspace that has not painted keeps the outgoing content on screen, and the
/// incoming one (which has the keyboard) invisible, until it paints (audit B1/B2, input-principles.md). The
/// person must see what they switched to in the switch's own frame: the hold lasts at most two frames, and a
/// key or a click in the window ends it before it is delivered, so no input goes to an invisible view.
@MainActor @Suite(.serialized) struct PanePaintHoldBoundTests {
    /// A pane in a real `ShellWindow` whose paint hold runs on `rig`'s deadlines.
    final class Pane {
        let window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                                 backing: .buffered, defer: false)
        let pane: PaneContentView

        init(rig: MainDeadlineRig) {
            pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("a"), title: "A")]),
                                   reveal: LaunchReveal(deadline: .zero), input: InputEventTap(),
                                   node: VisibilityNode(root: "pane:test", own: .visible), deadlines: rig.deadlines)
            window.isReleasedWhenClosed = false
            pane.barOrder = .aboveToolbar
            pane.frame = window.contentLayoutRect
            window.contentView = pane
            window.orderFrontRegardless()
        }

        func select(_ view: NSView) {
            pane.show(view)
            pane.layoutSubtreeIfNeeded()
        }

        func tearDown() {
            window.orderOut(nil)
            window.close()
        }
    }

    /// A page tab with no stand-in whose document never paints: the pane holds the old content for it.
    static func unpaintedPage(_ key: String) -> InternalPageView {
        InternalPageView(key: key, page: .settings, content: InternalPageStandInTests.page(), standInTitle: nil)
    }

    @Test func aHoldForAPageThatNeverPaintsEndsWithinTwoFrames() {
        let rig = MainDeadlineRig()
        let pane = Pane(rig: rig)
        defer { pane.tearDown() }
        let terminal = NSView()
        pane.select(terminal)
        let page = Self.unpaintedPage("local-page:settings:bound-a")
        pane.select(page)
        #expect(page.alphaValue == 0, "precondition: the switch holds the old content while the page has not painted")
        #expect(rig.hasArmedWake, "the hold armed no limit")
        rig.fireAndRun()
        #expect(rig.elapsed <= 0.034, "the old content stayed \(Int(rig.elapsed * 1000)) ms over the tab switched to (limit: two frames)")
        #expect(page.alphaValue == 1, "the tab switched to was still invisible at the hold's limit")
        #expect(terminal.superview == nil || terminal.isHidden, "the old content stayed on screen after the hold's limit")
    }

    @Test func aKeyInTheWindowEndsTheHoldBeforeItIsDelivered() throws {
        let rig = MainDeadlineRig()
        let pane = Pane(rig: rig)
        defer { pane.tearDown() }
        let terminal = NSView()
        pane.select(terminal)
        let page = Self.unpaintedPage("local-page:settings:bound-b")
        pane.select(page)
        #expect(page.alphaValue == 0, "precondition: the switch holds the old content while the page has not painted")
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: pane.window.windowNumber, context: nil, characters: "a",
                                                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        pane.window.sendEvent(key)
        #expect(page.alphaValue == 1, "a key typed during the hold went to the invisible tab")
        #expect(terminal.superview == nil || terminal.isHidden, "the old content stayed over the tab the key went to")
    }

    @Test func aClickInTheWindowEndsTheHold() throws {
        let rig = MainDeadlineRig()
        let pane = Pane(rig: rig)
        defer { pane.tearDown() }
        let terminal = NSView()
        pane.select(terminal)
        let page = Self.unpaintedPage("local-page:settings:bound-c")
        pane.select(page)
        #expect(page.alphaValue == 0, "precondition: the switch holds the old content while the page has not painted")
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 400, y: 200), modifierFlags: [],
                                                    timestamp: 0, windowNumber: pane.window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        pane.window.sendEvent(click)
        #expect(page.alphaValue == 1, "a click during the hold landed on the invisible tab")
    }
}
