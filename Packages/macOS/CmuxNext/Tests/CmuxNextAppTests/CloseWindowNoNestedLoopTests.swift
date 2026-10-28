import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// Close Window (Ctrl-Cmd-W, the menu, a script's closeWindow) must commit in its own turn. It called
/// `NSWindow.performClose(_:)`, which "simulates the user clicking the close button by momentarily
/// highlighting the button": AppKit's `-[NSButtonCell performClick:]` runs a nested event-tracking run
/// loop to flash the button, so the key turn took about 100 ms (v2.2.4-opt, cmux17 and cmux24:
/// `debug.action_budget` closeWindow `nested`, 101.7 and 102.8 ms; the stack is AppActions closure ->
/// `-[NSButtonCell performClick:]` -> `nextEventMatchingMask` with Chromium pump passes and a page PNG
/// encode inside it). Chrome closes a window without flashing its button.
@MainActor @Suite(.serialized) struct CloseWindowNoNestedLoopTests {
    private static func controller() throws -> (WindowController, AppServices) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"close-no-nested-loop","workspace_key":"cn1"}"#.utf8))
        let controller = WindowController(state: WindowState(record: record), services: services,
                                          frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        return (controller, services)
    }

    /// Counts run loop entries on the main run loop (any common mode, event tracking included) while `body` runs.
    private static func nestedRunLoops(during body: () -> Void) -> Int {
        var entries = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.entry.rawValue, true, 0) { _, _ in entries += 1 }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        body()
        return entries
    }

    @Test(arguments: [ActionOrigin.user, ActionOrigin.script])
    func closeWindowClosesInItsTurnWithNoNestedRunLoop(origin: ActionOrigin) throws {
        let (controller, _) = try Self.controller()
        let window = try #require(controller.window)
        defer {
            controller.teardown()
            window.close()
        }
        var closed = false
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in
            closed = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let entries = Self.nestedRunLoops { controller.performClose(by: origin) }

        #expect(entries == 0, "the close ran \(entries) nested run loop(s) on the key turn (the close button's flash)")
        #expect(closed, "the window did not close in the close's own turn")
    }
}
