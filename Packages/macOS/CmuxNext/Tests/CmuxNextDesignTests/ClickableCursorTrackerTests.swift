import AppKit
@testable import CmuxNextDesign
import Testing

/// The hand over native chrome while a Chromium page (a child window) has the key: cursor rects
/// work only in the key window, so the sidebar's New Workspace button and the titlebar's sidebar
/// toggle showed the arrow (Leo 2026-10-21: "STOP BUTTON, I HOVER OVER IT, MY CURSOR SHOULD ALSO
/// SEE IT AS CLICKABLE"). Their `ClickableCursorTracker` sets the cursor itself then.
@MainActor
struct ClickableCursorTrackerTests {
    /// A parent window with `button` at (10, 10, 40, 20) and a child window that has the key.
    private final class Host {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 300, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let child = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 300, height: 20), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        let button: ClickableButton
        var keyWindow: NSWindow?
        var topWindow: Int?
        var cursors: [NSCursor] = []

        init(_ button: ClickableButton = ClickableButton(frame: .zero), in container: NSView? = nil) {
            self.button = button
            window.isReleasedWhenClosed = false
            child.isReleasedWhenClosed = false
            window.addChildWindow(child, ordered: .above)
            let parent = container ?? window.contentView!
            if let container { window.contentView?.addSubview(container) }
            parent.addSubview(button)
            button.frame = NSRect(x: 10, y: 10, width: 40, height: 20)
            keyWindow = child
            topWindow = window.windowNumber
            let tracker = button.cursorTracker
            tracker.isKey = { [unowned self] in $0 === keyWindow }
            tracker.mouseLocation = { [unowned self] in window.convertPoint(toScreen: button.convert(NSPoint(x: 20, y: 10), to: nil)) }
            tracker.topWindowNumber = { [unowned self] _ in topWindow ?? 0 }
            tracker.setCursor = { [unowned self] in cursors.append($0) }
            tracker.currentCursor = { [unowned self] in cursors.last }
        }

        var tracker: ClickableCursorTracker { button.cursorTracker }
    }

    private final class RowHost: NSView, ClickableCursorHost {
        var changes = 0
        func clickableStateDidChange(_ view: NSView) { changes += 1 }
    }

    @Test func theButtonTracksThePointerInItsWindow() {
        let host = Host()
        host.button.viewDidMoveToWindow()
        #expect(host.button.trackingAreas.contains { $0.owner === host.tracker })
        #expect(host.button.trackingAreas.filter { $0.owner === host.tracker }.count == 1)
    }

    @Test func anEnabledButtonShowsTheHandWhileAChildWindowHasTheKey() {
        let host = Host()
        host.tracker.pointerEntered()
        #expect(host.cursors == [NSCursor.pointingHand])
        host.tracker.pointerMoved()
        #expect(host.cursors == [NSCursor.pointingHand, NSCursor.pointingHand])
        host.tracker.pointerExited()
        #expect(host.cursors.last === NSCursor.arrow)
    }

    @Test func theKeyWindowLeavesTheCursorToTheRects() {
        let host = Host()
        host.keyWindow = host.window
        host.tracker.pointerEntered()
        host.tracker.pointerMoved()
        host.tracker.pointerExited()
        #expect(host.cursors.isEmpty)
    }

    @Test func aDisabledButtonSetsNoCursor() {
        let host = Host()
        host.button.isEnabled = false
        host.tracker.pointerEntered()
        host.tracker.pointerMoved()
        #expect(host.cursors.isEmpty)
    }

    @Test func aWindowCoveredByAnotherSetsNoCursor() {
        let host = Host()
        host.topWindow = host.child.windowNumber
        host.tracker.pointerEntered()
        host.tracker.pointerMoved()
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

    /// The real conversion and topmost-window gate: a screen point becomes the window's point
    /// only while the window is the top one under it.
    @Test func thePointerIsReadInWindowCoordinatesOnlyInTheTopWindow() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 300, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var asked: NSPoint?
        let point = ClickableButton.pointer(in: window, screenPoint: NSPoint(x: 110, y: 215)) {
            asked = $0
            return window.windowNumber
        }
        #expect(point == NSPoint(x: 10, y: 15))
        #expect(asked == NSPoint(x: 110, y: 215))
        #expect(ClickableButton.pointer(in: window, screenPoint: NSPoint(x: 110, y: 215)) { _ in window.windowNumber + 1 } == nil)
    }
}
