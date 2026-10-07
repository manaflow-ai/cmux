import AppKit
@testable import CmuxNextDesign
import Testing

/// The shared rule for key panels (palette, group editor, Page Info): keys
/// only while the app is active; shown without them, the keys going to
/// another window of the app tell the owner to close it.
@MainActor
struct ActiveAppKeyPanelTests {
    static func panel(active: Bool) -> ActiveAppKeyPanel {
        let panel = ActiveAppKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isAppActive = { active }
        return panel
    }

    static func postBecameKey(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    @Test func keysOnlyWhileTheAppIsActive() {
        #expect(Self.panel(active: true).canBecomeKey)
        #expect(!Self.panel(active: false).canBecomeKey)
    }

    @Test func aKeylessPanelHearsOnceWhenAnotherWindowTakesTheKeys() {
        let panel = Self.panel(active: false)
        var calls = 0
        panel.onKeyElsewhere = { calls += 1 }
        panel.makeKey()
        #expect(!panel.isKeyWindow)
        Self.postBecameKey(panel)
        #expect(calls == 0, "its own key change is not elsewhere")
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        Self.postBecameKey(other)
        Self.postBecameKey(other)
        #expect(calls == 1)
    }

    @Test func aPanelThatMayTakeTheKeysDoesNotWatch() {
        let panel = Self.panel(active: true)
        var calls = 0
        panel.onKeyElsewhere = { calls += 1 }
        panel.orderOut(nil)
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        Self.postBecameKey(other)
        #expect(calls == 0)
    }

    @Test func orderingOutStopsWatching() {
        let panel = Self.panel(active: false)
        var calls = 0
        panel.onKeyElsewhere = { calls += 1 }
        panel.makeKey()
        panel.orderOut(nil)
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        Self.postBecameKey(other)
        #expect(calls == 0)
    }
}
