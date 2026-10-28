import AppKit
@testable import CmuxNextApp
import Testing

/// `debug.key` into a window that is not key (a capture slot's app runs in the background, so no window is key) goes
/// through the app's real event entry, as a key in the key window does, so the input latency tracker, the input tap and
/// the typing probe see it (first-seconds-lag.md: `debug.input` had no per-key rows from capture slots).
@MainActor @Suite struct DebugNativeInputEntryTests {
    @MainActor final class Entry {
        var received: [(type: NSEvent.EventType, window: NSWindow)] = []
    }

    @Test func aKeyForAWindowThatIsNotKeyGoesThroughTheAppEntryToThatWindow() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(!DebugNativeInput.usesAppKitPath(window), "the test window is not key")
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
                                                keyCode: 0))
        let entry = Entry()
        DebugNativeInput.sendThroughApp([key], to: window) { entry.received.append(($0.type, $1)) }
        #expect(entry.received.count == 1, "the key bypassed the app's sendEvent")
        #expect(entry.received.first?.type == .keyDown)
        #expect(entry.received.first?.window === window)
    }
}
