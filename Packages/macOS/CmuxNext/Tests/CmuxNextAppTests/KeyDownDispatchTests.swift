import AppKit
@testable import CmuxNextApp
import Testing

/// `ActionRegistry.isDispatchingKeyDown` decides whether a run is a key press: Copy with nothing
/// selected goes to the program for Cmd-C but is refused for a menu, palette or CLI Copy
/// (TerminalHandlers), and menu validation applies key-equivalent rules only to a key. The App
/// reads `CmuxApplication.dispatchingEvent`, never `NSApp.currentEvent`, which keeps the last key
/// after its dispatch: a CLI Copy after a key press would pass for Cmd-C.
@MainActor @Suite(.serialized)
struct KeyDownDispatchTests {
    @Test func aKeyWhoseDispatchEndedIsNoKeyDown() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                                characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        NSApp.postEvent(key, atStart: true)
        _ = NSApp.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: true)
        try #require(NSApp.currentEvent?.type == .keyDown, "the test could not leave a stale key in currentEvent")
        #expect(!services.registry.isDispatchingKeyDown(), "a key whose dispatch ended counts as a key-down dispatch")
    }
}
