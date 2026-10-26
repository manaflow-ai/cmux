import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import Testing

/// Task p04-input-062 of plans/cmux-next/chrome-parity/p04-input.md: `KeyRouter.hasDecided` is the
/// O(1) question Chromium's pre-key hook asks first. It holds for a key the dispatcher decided and
/// for Chromium's copy of it, and a decided key runs nothing in the Chromium hooks.
@MainActor @Suite struct KeyRouterHooksTests {
    /// The router holds the registry `unowned`; the suite keeps it.
    let registry: ActionRegistry
    let ran: Ran

    /// The actions that ran, in order.
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

    static func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16,
                    timestamp: TimeInterval = 1) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    /// The key the dispatcher decided, and the copy of it Chromium hands back (same time, key code,
    /// modifiers and characters), are decided; another key is not.
    @Test func aDecidedKeyAndChromiumsCopyOfItAreDecided() throws {
        let router = KeyRouter(registry: registry)
        let event = try Self.key("t", [.command], keyCode: 17, timestamp: 42)
        #expect(!router.hasDecided(event))
        router.decided.add(event)
        #expect(router.hasDecided(event))
        #expect(router.hasDecided(try Self.key("t", [.command], keyCode: 17, timestamp: 42)), "Chromium's copy of the key")
        #expect(!router.hasDecided(try Self.key("t", [.command], keyCode: 17, timestamp: 43)), "the next press of the key")
        #expect(!router.hasDecided(try Self.key("w", [.command], keyCode: 13, timestamp: 42)), "another key at the same time")
    }

    /// A key with no timestamp (AppKit's synthesized key bindings) is decided by identity only.
    @Test func aKeyWithNoTimestampIsDecidedByIdentityOnly() throws {
        let router = KeyRouter(registry: registry)
        let event = try Self.key("t", [.command], keyCode: 17, timestamp: 0)
        router.decided.add(event)
        #expect(router.hasDecided(event))
        #expect(!router.hasDecided(try Self.key("t", [.command], keyCode: 17, timestamp: 0)))
    }

    /// A decided key runs no action from the Chromium page and DevTools hooks.
    @Test func aDecidedKeyRunsNothingInTheChromiumHooks() throws {
        let router = KeyRouter(registry: registry)
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        for event in [try Self.key("t", [.command], keyCode: 17), try Self.key("i", [.command, .option], keyCode: 34)] {
            router.decided.add(event)
            #expect(router.browserTab(tab, keyEquivalent: event) == .passToPage)
            #expect(router.browserTab(tab, devToolsKeyEquivalent: event) == .passToPage)
        }
        #expect(ran.ids.isEmpty, "a decided key ran \(ran.ids)")
    }
}
