import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextSettings
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-06, on a ring that stayed lit around a pane he was not touching, flickering:
/// "i need the freaking focus ring to STOP FIRING SO OFTEN AND TO BE ABLE TO CANCEL IT JUST GETS
/// STUCK IN THESE SITUATIONS" and "WHY DOESN'T THE COMMAND PALETTE TOGGLE FOR FOCUS RINGS WORK FOR
/// TURNING IT OFF THIS IS NOT WORKING". Only the person's keys earn the focus ring; a click on
/// the focused pane or Escape takes it away at once; Toggle Focus Ring turns every pane ring off.
@MainActor
@Suite(.closesItsWindows, .serialized)
struct FocusRingEarnedTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Window {
        let provider = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
            .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))))], activeScreenID: "s", focusedPane: "p1")
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init() {
            root = LayoutRootView(model: model, contentProvider: provider)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }

        func ring(_ pane: PaneID) -> Bool? {
            root.syncWithModel()
            return root.overlayRings.first { $0.pane == pane.rawValue }?.showsRing
        }

        func center(_ pane: PaneID) throws -> CGPoint {
            let frame = try #require(root.frame(of: pane))
            return root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        }

        func key(_ code: UInt16, from source: NSWindow? = nil) { root.handleMonitoredKey(code, from: source ?? window) }
    }

    /// The ring draws only with the setting on and the border indicator (the SplitFocusRingTests setup).
    private static func withRing(_ body: () throws -> Void) rethrows {
        let indicator = DesignSettings.shared.focusIndicator
        let ring = DesignSettings.shared.focusRing
        DesignSettings.shared.focusIndicator = .both
        DesignSettings.shared.focusRing.enabled = true
        defer {
            DesignSettings.shared.focusIndicator = indicator
            DesignSettings.shared.focusRing = ring
        }
        try body()
    }

    @Test func onlyAKeyMoveEarnsTheRing() {
        let model = FocusMoveRingFlashTests.threePanes()
        model.focus("b", notify: false)
        #expect(!model.focusRingEarned, "a move nobody keyed (an agent, the CLI, a new pane) drew the ring")
        model.focus("c", notify: false, source: .keyboard)
        model.focus("c", notify: false) // the focus coordinator's mirror of the same move
        #expect(model.focusRingEarned)
        model.focus("a", source: .pointer)
        #expect(!model.focusRingEarned)
        model.focus("b", source: .keyboard)
        model.focus("c", source: .scroll)
        #expect(!model.focusRingEarned)
    }

    @Test func aProgrammaticMoveDrawsNoRing() throws {
        try Self.withRing {
            let w = Window()
            defer { w.window.closeAfterTest() }
            w.model.focus("p2", notify: false)
            #expect(w.ring("p2") == false)
            w.model.focus("p1", source: .keyboard)
            #expect(w.ring("p1") == true)
            #expect(w.ring("p2") == false)
        }
    }

    @Test func aClickOnTheFocusedPaneClearsItsRingAtOnce() throws {
        try Self.withRing {
            let w = Window()
            defer { w.window.closeAfterTest() }
            w.model.focus("p2", source: .keyboard)
            #expect(w.ring("p2") == true)
            w.root.handleMonitoredPress(at: try w.center("p2"))
            #expect(w.model.focusedPane == "p2")
            #expect(w.ring("p2") == false, "the ring stayed after a click on its own pane")
        }
    }

    @Test func escapeClearsTheRingAndFocusStays() throws {
        try Self.withRing {
            let w = Window()
            defer { w.window.closeAfterTest() }
            w.model.focus("p2", source: .keyboard)
            #expect(w.ring("p2") == true)
            w.key(0) // A
            #expect(w.ring("p2") == true, "a key other than Escape cleared the ring")
            w.key(53) // Escape
            #expect(w.model.focusedPane == "p2")
            #expect(w.ring("p2") == false, "Escape left the ring")
        }
    }

    /// A pointer move takes the ring away (ask-020e093fab: "any click, Escape or pointer move away
    /// dismisses it"); a hand resting on the trackpad, a point or two, does not.
    @Test func aPointerMoveClearsTheRing() throws {
        try Self.withRing {
            let w = Window()
            defer { w.window.closeAfterTest() }
            w.model.focus("p2", source: .keyboard)
            w.root.handlePointerTravel(2)
            #expect(w.ring("p2") == true, "a jitter of 2 points cleared the ring")
            w.root.handlePointerTravel(12)
            #expect(w.model.focusedPane == "p2")
            #expect(w.ring("p2") == false, "the ring stayed after the pointer moved")
            w.model.focus("p1", source: .keyboard)
            w.root.handlePointerTravel(2)
            #expect(w.ring("p1") == true, "travel before the ring was earned counted against the next one")
            w.key(53) // Escape, with 2 points of travel counted
            w.model.focus("p2", source: .keyboard)
            #expect(w.ring("p2") == true)
            w.root.handlePointerTravel(5)
            #expect(w.ring("p2") == true, "travel from before Escape counted against the next ring")
            w.model.focus("p1", source: .keyboard) // the ring moves by key while it is earned
            #expect(w.ring("p1") == true) // the view takes the move (syncs) before the pointer moves
            w.root.handlePointerTravel(5)
            #expect(w.ring("p1") == true, "travel on the previous pane counted against the ring's new pane")
        }
    }

    /// A Chromium page is a child window: its pointer moves reach only the event monitor, and they
    /// clear the ring too; an unrelated window's do not.
    @Test func aPointerMoveInAPagesChildWindowClearsTheRing() throws {
        try Self.withRing {
            let w = Window()
            let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
            w.window.addChildWindow(child, ordered: .above)
            defer {
                w.window.removeChildWindow(child)
                child.closeAfterTest()
                other.closeAfterTest()
                w.window.closeAfterTest()
            }
            w.model.focus("p2", source: .keyboard)
            w.root.handleMonitoredPointerMove(20, from: other)
            #expect(w.ring("p2") == true, "a move in an unrelated window cleared the ring")
            w.root.handleMonitoredPointerMove(20, from: child)
            #expect(w.ring("p2") == false, "a move over a page's child window left the ring")
        }
    }

    /// A Chromium page's keys come from its child window: Escape there clears the ring too, and
    /// Escape in an unrelated window does not.
    @Test func escapeInAPagesChildWindowClearsTheRing() throws {
        try Self.withRing {
            let w = Window()
            let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
            defer {
                w.window.removeChildWindow(child)
                child.closeAfterTest()
                other.closeAfterTest()
                w.window.closeAfterTest()
            }
            w.window.addChildWindow(child, ordered: .above)
            w.model.focus("p2", source: .keyboard)
            w.key(53, from: other)
            #expect(w.ring("p2") == true, "Escape in another window cleared this one's ring")
            w.key(53, from: child)
            #expect(w.ring("p2") == false, "Escape in a page's child window left the ring")
        }
    }

    /// Toggle Focus Ring reads on while any pane ring can draw, and off turns every one off.
    @Test func theToggleTurnsEveryPaneRingOff() {
        let design = DesignSettings.shared
        let ring = design.focusRing, attention = design.attention
        defer {
            design.focusRing = ring
            design.attention = attention
        }
        design.focusRing.enabled = false
        design.attention = AttentionSettings()
        #expect(design.attention.drawsAnyRing, "the unread glow is on by default")
        #expect(design.showsAnyPaneRing, "the toggle read off while the unread ring could draw")
        design.attention.terminalRing = .none
        #expect(!design.showsAnyPaneRing)
        design.attention.agentChatRing = .ring
        #expect(design.showsAnyPaneRing)
        design.attention.agentChatRing = .none
        design.focusRing.enabled = true
        #expect(design.showsAnyPaneRing)
        // Off from the defaults plus the ring: every pane ring goes, live and in cmux.json.
        design.attention = AttentionSettings()
        let off = design.togglePaneRings()
        #expect(!design.focusRing.enabled && !design.attention.drawsAnyRing)
        #expect(off.map(\.0) == [["focusRing", "enabled"], ["notifications", "attention", "terminals"],
                                  ["notifications", "attention", "agentChats"]])
        #expect(off.map(\.1) == [.bool(false), .string("none"), .string("none")])
        let on = design.togglePaneRings()
        #expect(design.focusRing.enabled && !design.attention.drawsAnyRing)
        #expect(on.map(\.1) == [.bool(true)])
    }

    /// A pane-navigation action the CLI, an agent or a script runs moves focus nobody keyed.
    @Test func onlyThePersonsOwnRunOfAFocusKeyEarnsTheRing() {
        #expect(ColumnFocusSource.keyMove(byPerson: ActionInvocation(origin: .user).isPersonsOwnRun) == .keyboard)
        #expect(ColumnFocusSource.keyMove(byPerson: ActionInvocation(origin: .cli).isPersonsOwnRun) == .programmatic)
    }

    /// A screen switch that puts focus on the new screen's first pane: nobody keyed it.
    @Test func aScreenSwitchStandInHasNoRing() {
        let model = LayoutModel(screens: [
            LayoutScreen(id: "s1", name: "s1", layout: .splits(.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")))),
            LayoutScreen(id: "s2", name: "s2", layout: .splits(.leaf("c"))),
        ], activeScreenID: "s1", focusedPane: "a")
        model.focus("b", source: .keyboard)
        #expect(model.focusRingEarned)
        model.selectScreen("s2")
        #expect(model.focusedPane == "c")
        #expect(!model.focusRingEarned, "the screen switch's stand-in pane kept the ring")
    }

    /// A press in a pane's child window (a Chromium page) clears the ring; one in another window does not.
    @Test func aPressInAPagesChildWindowClearsTheRing() throws {
        try Self.withRing {
            let w = Window()
            let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
            // A divider's mouse catcher or an overlay is a child panel, not a page.
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 20, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            defer {
                w.window.removeChildWindow(child)
                w.window.removeChildWindow(panel)
                child.closeAfterTest()
                panel.closeAfterTest()
                w.window.closeAfterTest()
            }
            w.window.addChildWindow(child, ordered: .above)
            w.window.addChildWindow(panel, ordered: .above)
            w.model.focus("p2", source: .keyboard)
            #expect(w.ring("p2") == true)
            #expect(!w.root.handleMonitoredChildPress(from: w.window), "a press in the window itself is not a child's")
            #expect(!w.root.handleMonitoredChildPress(from: panel), "a press in a child panel (a divider catcher) cleared the ring")
            #expect(w.ring("p2") == true)
            #expect(w.root.handleMonitoredChildPress(from: child))
            #expect(w.ring("p2") == false, "a press in the page's child window left the ring")
        }
    }
}
