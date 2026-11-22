import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The bookmark edit bubble (a ``NativePopupHost`` panel) holds a Folder picker whose menu is
/// AppKit's, a window of its own. Opening it took the keys from the bubble, and the host read
/// that key loss as a dismiss: a click on the picker closed the bubble. A menu opened from inside
/// a popup is part of it: a click, Escape or a pick closes only the menu, and the popup stays.
@MainActor @Suite(.serialized, .closesItsWindows) struct NativePopupHostChildMenuTests {
    /// The notices this test posts go here only (a fresh center per test).
    private let center = NotificationCenter()

    /// The bubble's shape: a visible window, and over it a keyed popup panel whose card holds the
    /// Folder picker (a `ThemedPopUpButton`, as `ThemedPicker` makes). The host observes `center`,
    /// the test's own, so the menu notices reach no other observer in the process.
    private static func bubble(center: NotificationCenter) throws -> (NSWindow, NativePopupHost, ThemedPopUpButton) {
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        let panel = NativePopupPanel(identifier: "cmux.tests.popup-child-menu")
        let picker = ThemedPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 24), pullsDown: false)
        for title in ["Bookmarks Bar", "    Work", "Other Bookmarks"] {
            picker.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        content.addSubview(picker)
        panel.adoptPopupStyle(card: Glass.makeOverlayPanel(content: content, cornerRadius: PopupStyle.standard.cornerRadius))
        let host = NativePopupHost(panel: panel, notificationCenter: center)
        let anchor = CGRect(x: window.frame.midX, y: window.frame.maxY - 60, width: 20, height: 20)
        try #require(host.show(size: CGSize(width: 220, height: 80), anchor: anchor, in: window) != nil)
        return (window, host, picker)
    }

    private static func close(_ window: NSWindow, _ host: NativePopupHost) {
        host.closePanel()
        window.closeAfterTest()
    }

    /// Fails before the fix: the picker's menu took the keys and the bubble closed under it.
    @Test func thePickersMenuTakingTheKeysLeavesTheBubbleOpen() throws {
        let (window, host, picker) = try Self.bubble(center: center)
        defer { Self.close(window, host) }
        var dismissed = 0
        host.onDismiss = { dismissed += 1 }
        let menu = try #require(picker.menu)

        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        // The menu's window becomes key: the popup panel resigns.
        host.panel.resignKey()
        #expect(host.isShown, "opening the Folder picker closed the bubble")
        #expect(dismissed == 0)

        // A pick (or a click elsewhere, or Escape) ends the menu; the bubble stays.
        picker.selectItem(at: 1)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(host.isShown, "closing the Folder picker's menu closed the bubble")
        #expect(dismissed == 0)
    }

    /// Passes before and after: with no menu of its own open, the bubble losing the keys (another
    /// window or a menu that is not the bubble's took them) still closes it.
    @Test func losingTheKeysToSomethingElseStillClosesTheBubble() throws {
        let (window, host, _) = try Self.bubble(center: center)
        defer { Self.close(window, host) }
        var dismissed = 0
        host.onDismiss = { dismissed += 1 }
        let elsewhere = NSMenu(title: "Elsewhere")
        elsewhere.addItem(withTitle: "Item", action: nil, keyEquivalent: "")

        center.post(name: NSMenu.didBeginTrackingNotification, object: elsewhere)
        host.panel.resignKey()
        center.post(name: NSMenu.didEndTrackingNotification, object: elsewhere)

        #expect(!host.isShown)
        #expect(dismissed == 1)
    }

    /// A press in the popup at its window (the event AppKit is handling when the panel resigns).
    private static func press(in panel: NSPanel) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// The main queue gets a turn (the check a key loss during a press schedules).
    private static func afterThePress() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    /// AppKit may resign the panel before the picker's menu begins tracking: the press in the
    /// popup holds the dismiss until the menu shows, and the menu keeps the bubble open.
    @Test func theKeysLostBeforeThePickersMenuBeginsLeaveTheBubbleOpen() async throws {
        let (window, host, picker) = try Self.bubble(center: center)
        defer { Self.close(window, host) }
        var dismissed = 0
        host.onDismiss = { dismissed += 1 }
        let menu = try #require(picker.menu)

        host.lostKeys(elsewhere: false, press: try Self.press(in: host.panel))
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        try await Self.afterThePress()
        #expect(host.isShown, "the Folder picker's menu closed the bubble")

        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        try await Self.afterThePress()
        #expect(host.isShown)
        #expect(dismissed == 0)
    }

    /// A press in the popup that gives the keys to a window that is not its child (no menu of the
    /// popup began) still closes it: the popup never sticks open.
    @Test func aPressInThePopupThatGivesTheKeysAwayStillClosesIt() async throws {
        let (window, host, _) = try Self.bubble(center: center)
        defer { Self.close(window, host) }
        var dismissed = 0
        host.onDismiss = { dismissed += 1 }

        host.lostKeys(elsewhere: false, press: try Self.press(in: host.panel))
        #expect(host.isShown, "the check waits until the press is handled")
        try await Self.afterThePress()

        #expect(!host.isShown, "a press that opened no menu of the popup left it stuck open")
        #expect(dismissed == 1)
    }
}
