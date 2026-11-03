import AppKit
@testable import CmuxNextApp
import Testing

/// `ActionRegistry.isDispatchingKeyDown` decides whether a run is a key press: Copy with nothing
/// selected goes to the program for Cmd-C but is refused for a menu, palette or CLI Copy
/// (TerminalHandlers), and menu validation applies key-equivalent rules only to a key. The App
/// reads its input dispatch context (`InputDispatchContext`), never `NSApp.currentEvent`, which keeps the last key
/// after its dispatch: a CLI Copy after a key press would pass for Cmd-C.
@MainActor @Suite(.serialized)
struct KeyDownDispatchTests {
    @Test func aKeyWhoseDispatchEndedIsNoKeyDown() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                                characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        // AppKit's event queue (postEvent, then nextEvent, in any run loop mode) ended the whole
        // test process on the fleet's macOS 26 minis, so the stale key goes straight into the ivar
        // `currentEvent` returns, as a finished dispatch leaves it.
        try #require(class_getInstanceVariable(NSApplication.self, "_currentEvent") != nil,
                     "NSApplication has no _currentEvent ivar on this macOS")
        NSApp.setValue(key, forKey: "currentEvent")
        defer { NSApp.setValue(nil, forKey: "currentEvent") }
        try #require(NSApp.currentEvent?.type == .keyDown, "the test could not leave a stale key in currentEvent")
        #expect(!services.registry.isDispatchingKeyDown(), "a key whose dispatch ended counts as a key-down dispatch")
    }
}
