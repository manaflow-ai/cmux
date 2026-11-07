import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextOnboarding
import CmuxNextTestSupport
import Testing

/// P0 ctrlbt-real-palette: at first run the Agents window (#36372) is key and in front of Home.
/// A real Ctrl-` there ran nothing: New Terminal Tab has no menu item, and the key dispatcher
/// decided keys for main windows only. Now a keyboard-only cmux shortcut in an onboarding tool
/// window runs in the main window behind it.
@MainActor @Suite(.serialized, .closesItsWindows) struct ToolWindowKeysTests {
    /// The router holds the registry `unowned`; the suite keeps it.
    let registry: ActionRegistry
    let ran: Ran

    @MainActor final class Ran { var ids: [String] = [] }

    init() {
        let registry = ActionRegistry.standard()
        let ran = Ran()
        for descriptor in ActionCatalog.all {
            let id = descriptor.id
            registry.bind(id) { ran.ids.append(id.rawValue) }
        }
        self.registry = registry
        self.ran = ran
    }

    static func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    /// The first-run Agents window, as the app makes it (not shown on screen).
    static func agentsWindow() throws -> (OnboardingWindowController, NSWindow) {
        let controller = OnboardingWindowController(model: OnboardingModel(services: MockOnboardingServices(), step: .agents), activeLook: nil)
        return (controller, try #require(controller.window))
    }

    @Test func ctrlBacktickInTheAgentsWindowRunsNewTerminalTab() throws {
        let (controller, window) = try Self.agentsWindow()
        defer { controller.close() }
        let router = KeyRouter(registry: registry)
        let ctrlBacktick = try Self.key("`", [.control], keyCode: 50)
        #expect(router.interceptKeyDown(ctrlBacktick, in: window), "the tool window must not swallow Ctrl-`")
        #expect(ran.ids == ["newSurface"])
        #expect(router.decided.contains(ctrlBacktick), "the menu must not run it again")
    }

    /// Return and Escape (the window's own keys), typing and menu actions (Cmd-W closes the tool
    /// window through the menu) stay with the window and AppKit.
    @Test func theWindowKeepsItsOwnKeysAndMenuKeys() throws {
        let (controller, window) = try Self.agentsWindow()
        defer { controller.close() }
        let router = KeyRouter(registry: registry)
        #expect(!router.interceptKeyDown(try Self.key("\r", [], keyCode: 36), in: window))
        #expect(!router.interceptKeyDown(try Self.key("a", [], keyCode: 0), in: window))
        #expect(!router.interceptKeyDown(try Self.key("w", [.command], keyCode: 13), in: window))
        #expect(ran.ids.isEmpty)
    }

    /// Only onboarding tool windows: a window no owner gave a kind is left as before.
    @Test func aKindlessWindowIsLeftAlone() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let router = KeyRouter(registry: registry)
        #expect(!router.interceptKeyDown(try Self.key("`", [.control], keyCode: 50), in: window))
        #expect(ran.ids.isEmpty)
    }
}
