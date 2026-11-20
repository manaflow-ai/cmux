import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import CmuxNextTestSupport
import Testing

/// The close key of a window that closes as a whole (Settings, Page Info, a browser popup, Debug Settings, a
/// kind-less closable window: `WindowKeyBehavior.closeWindow`) closes it in the key's turn without
/// `NSWindow.performClose(_:)`. That call flashes the close button through `-[NSButtonCell performClick:]`, a
/// nested event-tracking run loop of about 100 ms on the key turn (dogfood v2.2.4-opt: Close Window 101.7 and
/// 102.8 ms, outcome nested). In a test process AppKit skips the flash itself, so this suite reads the call
/// that flashes: a window that counts its `performClose(_:)`.
@MainActor @Suite(.serialized, .closesItsWindows) struct CloseKeyNoButtonFlashTests {
    /// Counts `performClose(_:)` and still closes as AppKit does.
    final class PerformCloseCountingWindow: NSWindow {
        var performCloses = 0
        override func performClose(_ sender: Any?) {
            performCloses += 1
            super.performClose(sender)
        }
    }

    /// A delegate that keeps the window open (a confirmation that the person has not answered).
    final class DecliningDelegate: NSObject, NSWindowDelegate {
        var asks = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            asks += 1
            return false
        }
    }

    private static func window() -> PerformCloseCountingWindow {
        _ = NSApplication.shared
        let window = PerformCloseCountingWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                                styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func services(keyWindow window: NSWindow) -> AppServices {
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.keyWindowSource = { [weak window] in window }
        return services
    }

    /// Cmd-W in a window of its own closes that window in the key's turn, with no button flash.
    @Test func theCloseKeyClosesAWindowOfItsOwnWithoutTheButtonFlash() {
        let window = Self.window()
        window.orderFront(nil)
        defer { window.close() }
        let services = Self.services(keyWindow: window)

        _ = services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))

        #expect(window.performCloses == 0, "the close key called performClose(_:), whose button flash is a nested run loop")
        #expect(!window.isVisible, "the close key did not close the window in its turn")
    }

    /// The window's delegate still decides, as for its close button.
    @Test func theWindowsDelegateStillDecides() {
        let window = Self.window()
        let delegate = DecliningDelegate()
        window.delegate = delegate
        window.orderFront(nil)
        defer {
            window.delegate = nil
            window.close()
        }
        let services = Self.services(keyWindow: window)

        _ = services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))

        #expect(delegate.asks == 1, "the delegate was not asked")
        #expect(window.isVisible, "the window closed although its delegate kept it open")
        #expect(window.performCloses == 0, "the close key called performClose(_:)")
    }
}
