import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextFocus
import Testing

/// Task p04-input-062 of plans/cmux-next/chrome-parity/p04-input.md: `KeyRouter.decidedKey` is the
/// O(1) question Chromium's pre-key hook asks first. It holds for a key the dispatcher decided and
/// for Chromium's copy of it, a decided key runs nothing in the Chromium hooks, and a decided key
/// whose extension shortcuts the dispatcher did not look up still owes that step to the hook.
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
        #expect(router.decidedKey(event) == .undecided)
        router.decided.add(event)
        #expect(router.decidedKey(event) != .undecided)
        #expect(router.decidedKey(try Self.key("t", [.command], keyCode: 17, timestamp: 42)) != .undecided, "Chromium's copy of the key")
        #expect(router.decidedKey(try Self.key("t", [.command], keyCode: 17, timestamp: 43)) == .undecided, "the next press of the key")
        #expect(router.decidedKey(try Self.key("w", [.command], keyCode: 13, timestamp: 42)) == .undecided, "another key at the same time")
    }

    /// A key with no timestamp (AppKit's synthesized key bindings) is decided by identity only.
    @Test func aKeyWithNoTimestampIsDecidedByIdentityOnly() throws {
        let router = KeyRouter(registry: registry)
        let event = try Self.key("t", [.command], keyCode: 17, timestamp: 0)
        router.decided.add(event)
        #expect(router.decidedKey(event) != .undecided)
        #expect(router.decidedKey(try Self.key("t", [.command], keyCode: 17, timestamp: 0)) == .undecided)
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

    /// Cmd-F the dispatcher offered to the page, or any decided chord while a cmux page in Chromium
    /// (no pane's Chromium tab) has the keyboard: the dispatcher looked up no extension shortcut, so
    /// Chromium's hook still owes the key that step. Browser focus mode settles it (the page owns
    /// every key), for Chromium's copy of the key too.
    @Test func aDecidedKeyOwesTheExtensionStepUntilTheDispatcherLookedItUp() throws {
        let router = KeyRouter(registry: registry)
        let offered = try Self.key("f", [.command], keyCode: 3, timestamp: 7)
        router.decided.add(offered)
        #expect(router.decidedKey(offered) == .extensionShortcutOwed)
        #expect(!router.runExtensionShortcut(offered, focus: FocusState()))
        #expect(router.decidedKey(offered) == .extensionShortcutOwed, "no Chromium tab's shortcuts were read")

        let focusModeKey = try Self.key("k", [.command], keyCode: 40, timestamp: 8)
        var focusMode = FocusState()
        focusMode.isBrowserFocusModeActive = true
        router.decided.add(focusModeKey)
        #expect(!router.runExtensionShortcut(focusModeKey, focus: focusMode))
        #expect(router.decidedKey(focusModeKey) == .settled)
        #expect(router.decidedKey(try Self.key("k", [.command], keyCode: 40, timestamp: 8)) == .settled, "Chromium's copy of the key")
        #expect(ran.ids.isEmpty, "a decided key ran \(ran.ids)")
    }
}
