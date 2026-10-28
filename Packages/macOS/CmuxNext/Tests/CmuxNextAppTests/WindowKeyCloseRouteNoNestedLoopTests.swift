import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The close key of a window that closes as a whole goes through the registry's key window route
/// (`WindowKeyTable`'s `.closeWindow`). On the base that route ran `performClose(nil)`, whose close button
/// flash is a nested event-tracking run loop of about 100 ms on the key turn (as Close Window on main
/// windows, v2.2.4-opt: action budget `nested`, 102 ms; handoff/v224-gate-triage.md). This test drives the
/// key's real path (the route installed as the app installs it, the window as the key window, the person's
/// close action through `ActionRegistry.perform`) and uses no API the fix adds, so it is red on the base.
@MainActor @Suite(.serialized) struct WindowKeyCloseRouteNoNestedLoopTests {
    /// Counts run loop entries on the main run loop (any common mode, event tracking included) while `body` runs.
    private static func nestedRunLoops(during body: () -> Void) -> Int {
        var entries = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.entry.rawValue, true, 0) { _, _ in entries += 1 }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        body()
        return entries
    }

    @Test func theCloseKeyOfAPlainWindowClosesItInTheKeysTurnWithNoNestedRunLoop() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        WindowKeyTable.install(services)
        // A closable window with no owner and no kind: its close key closes the window (KeyWindowRole).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        services.keyWindowSource = { [window] in window }

        var ran = false
        let entries = Self.nestedRunLoops {
            ran = services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
        }

        #expect(ran, "the key window route did not run the close")
        #expect(entries == 0, "the close key ran \(entries) nested run loop(s) on the key turn (the close button's flash)")
        #expect(!window.isVisible, "the window did not close in the key's turn")
    }
}
