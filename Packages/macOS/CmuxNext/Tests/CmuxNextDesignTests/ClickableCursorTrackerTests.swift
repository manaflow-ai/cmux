import AppKit
@testable import CmuxNextDesign
import Testing

/// The hand over native chrome while a Chromium page (a child window) has the key: cursor rects
/// work only in the key window, so the sidebar's New Workspace button and the titlebar's sidebar
/// toggle showed the arrow (Leo 2026-10-21: "STOP BUTTON, I HOVER OVER IT, MY CURSOR SHOULD ALSO
/// SEE IT AS CLICKABLE"). Their `ClickableCursorTracker` sets the cursor itself then.
@MainActor
@Suite(.serialized)
struct ClickableCursorTrackerTests {
    /// A parent window with buttons in it and a child window that has the key. `pointer` is where
    /// the pointer is, in the parent window's coordinates; `childOnTop` puts the child window over
    /// it (windows never ordered in have no reliable window numbers, so the host answers for the
    /// window list); `cursors` is every cursor set, the last one showing. The shared `owner` starts
    /// empty, so no earlier case's tracker leaks in.
    private final class Host {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 300, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let child = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 300, height: 20), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        var buttons: [ClickableButton] = []
        var keyWindow: NSWindow?
        var childOnTop = false
        var pointer = NSPoint(x: 30, y: 20)
        var cursors: [NSCursor] = []

        init(in container: NSView? = nil) {
            window.isReleasedWhenClosed = false
            child.isReleasedWhenClosed = false
            window.addChildWindow(child, ordered: .above)
            if let container { window.contentView?.addSubview(container) }
            keyWindow = child
            ClickableCursorTracker.owner = nil
            add(at: NSRect(x: 10, y: 10, width: 40, height: 20), in: container)
        }

        @discardableResult
        func add(at frame: NSRect, in container: NSView? = nil) -> ClickableButton {
            let button = ClickableButton(frame: frame)
            (container ?? window.contentView!).addSubview(button)
            let tracker = button.cursorTracker
            tracker.isKey = { [weak self] in $0 === self?.keyWindow }
            tracker.mouseLocation = { [weak self] in self.map { $0.window.convertPoint(toScreen: $0.pointer) } ?? .zero }
            tracker.topWindowNumber = { [weak self] _ in
                guard let self, !self.childOnTop else { return Int.min }
                return self.window.windowNumber
            }
            tracker.setCursor = { [weak self] in self?.cursors.append($0) }
            tracker.currentCursor = { [weak self] in self?.cursors.last }
            buttons.append(button)
            return button
        }

        var button: ClickableButton { buttons[0] }
        var tracker: ClickableCursorTracker { button.cursorTracker }
    }

    private final class RowHost: NSView, ClickableCursorHost {
        var changes = 0
        func clickableStateDidChange(_ view: NSView) { changes += 1 }
    }

    @Test func theButtonTracksThePointerInItsWindow() {
        let host = Host()
        host.button.viewDidMoveToWindow()
        #expect(host.button.trackingAreas.filter { $0.owner === host.tracker }.count == 1)
    }

    @Test func anEnabledButtonShowsTheHandWhileAChildWindowHasTheKey() {
        let host = Host()
        host.tracker.pointerEntered()
        #expect(host.cursors == [NSCursor.pointingHand])
        #expect(ClickableCursorTracker.owner === host.tracker)
        host.tracker.pointerMoved()
        #expect(host.cursors == [NSCursor.pointingHand, NSCursor.pointingHand])
        host.tracker.pointerExited()
        #expect(host.cursors.last === NSCursor.arrow)
        #expect(ClickableCursorTracker.owner == nil)
    }

    @Test func theKeyWindowLeavesTheCursorToTheRects() {
        let host = Host()
        host.keyWindow = host.window
        host.tracker.pointerEntered()
        host.tracker.pointerMoved()
        host.tracker.pointerExited()
        #expect(host.cursors.isEmpty)
    }

    @Test func aDisabledButtonOrACoveredWindowSetsNoCursor() {
        let host = Host()
        host.button.isEnabled = false
        host.tracker.pointerEntered()
        #expect(host.cursors.isEmpty)
        host.childOnTop = true
        host.button.isEnabled = true
        host.tracker.pointerEntered()
        #expect(host.cursors.isEmpty)
    }

    @Test func aDisableAndReEnableUnderTheStillPointerFollowsTheButton() {
        let host = Host()
        host.tracker.pointerEntered()
        host.button.isEnabled = false
        #expect(host.cursors == [NSCursor.pointingHand, NSCursor.arrow])
        host.button.isEnabled = true
        #expect(host.cursors == [NSCursor.pointingHand, NSCursor.arrow, NSCursor.pointingHand])
    }

    /// AppKit does not order one view's exit before the next view's enter: B's enter comes first,
    /// takes the hand, and A's late exit leaves it.
    @Test func aLateExitLeavesTheNextButtonsHand() {
        let host = Host()
        let other = host.add(at: NSRect(x: 50, y: 10, width: 40, height: 20))
        host.tracker.pointerEntered()
        host.pointer = NSPoint(x: 70, y: 20)
        other.cursorTracker.pointerEntered()
        #expect(ClickableCursorTracker.owner === other.cursorTracker)
        host.tracker.pointerExited()
        #expect(host.cursors == [NSCursor.pointingHand, NSCursor.pointingHand])
        other.cursorTracker.pointerExited()
        #expect(host.cursors.last === NSCursor.arrow, "B's own exit still clears its hand")
    }

    /// A's exit was swallowed (a menu's tracking loop) and the pointer went onto the page, which set
    /// its own hand: a later hide or disable of A leaves the page's hand.
    @Test func aSwallowedExitNeverPutsTheArrowOverThePage() {
        let host = Host()
        host.tracker.pointerEntered()
        host.childOnTop = true
        host.cursors.append(NSCursor.pointingHand) // the page's link
        host.button.isEnabled = false
        host.button.isHidden = true
        #expect(host.cursors.last === NSCursor.pointingHand)
        #expect(!host.cursors.contains { $0 === NSCursor.arrow })
    }

    /// The key child window reset the cursor in its display cycle (a page reload) under a still
    /// pointer: the keeper's pass sets the owner's hand again.
    @Test func theKeeperSetsTheHandAgainAfterADisplayCycleReset() {
        let host = Host()
        host.tracker.pointerEntered()
        host.cursors.append(NSCursor.arrow) // the child window's reset
        ClickableCursorTracker.keepHand()
        #expect(host.cursors.last === NSCursor.pointingHand)
        let count = host.cursors.count
        ClickableCursorTracker.keepHand()
        #expect(host.cursors.count == count, "a pass with the hand showing sets nothing")
    }

    /// The pointer left with no exit (a menu): the keeper gives up the hand and sets nothing.
    @Test func theKeeperGivesUpTheHandOnceThePointerLeft() {
        let host = Host()
        host.tracker.pointerEntered()
        host.pointer = NSPoint(x: 200, y: 80)
        host.cursors.append(NSCursor.iBeam)
        ClickableCursorTracker.keepHand()
        #expect(host.cursors.last === NSCursor.iBeam)
        #expect(ClickableCursorTracker.owner == nil)
    }

    /// A button hidden under the pointer gets no exit: the hand goes, and a later state change
    /// sets nothing.
    @Test func aHideWithNoExitClearsTheHand() {
        let host = Host()
        host.tracker.pointerEntered()
        host.button.isHidden = true
        #expect(host.cursors.last === NSCursor.arrow)
        let count = host.cursors.count
        host.button.isHidden = false
        host.button.isEnabled = false
        host.button.isEnabled = true
        #expect(host.cursors.count == count)
    }

    /// Another view set its own cursor after the hand (a terminal's I-beam): the exit leaves it.
    @Test func anExitKeepsACursorAnotherViewSet() {
        let host = Host()
        host.tracker.pointerEntered()
        host.cursors.append(NSCursor.iBeam)
        host.tracker.pointerExited()
        #expect(host.cursors.last === NSCursor.iBeam)
    }

    /// Inside a view that sets the cursor itself (the browser toolbar row), the row owns it.
    @Test func aButtonInsideACursorHostLeavesTheCursorToTheHost() {
        let row = RowHost(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let host = Host(in: row)
        host.tracker.pointerEntered()
        host.tracker.pointerMoved()
        host.tracker.pointerExited()
        #expect(host.cursors.isEmpty)
        host.button.isEnabled = false
        #expect(row.changes == 1)
    }
}
