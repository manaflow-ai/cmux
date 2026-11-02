import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// Typing into an agent chat after a Markdown file opened beside it (#25666). The focus model
/// named the Markdown page while the chat's Chromium page window had the keys: the key router
/// queued every printable key for the Markdown page, whose document had not focused an input
/// yet, and the chat got nothing. A key AppKit sends to another page's window is that page's.
@MainActor @Suite struct KeyInOtherPageWindowTests {
    static let registry = ActionRegistry.standard()

    static func key(_ characters: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    static func focus(_ resolved: FocusState.Resolved) -> FocusState {
        var focus = FocusState()
        focus.resolved = resolved
        return focus
    }

    static let markdown = focus(.page(pane: "pane_markdown", tab: "tab_markdown"))

    /// The Markdown page has the focus and cannot take typing yet: a key in its own window waits for it.
    @Test func aKeyForTheFocusedPageWaitsForItsInput() throws {
        let facts = KeyFacts(pageInputPending: true, pageID: KeyRouter.markdownPageID)
        #expect(KeyRouter(registry: Self.registry).decide(try Self.key("b", keyCode: 11), focus: Self.markdown,
                                                          keyWindow: .content, facts: facts) == .typeAhead)
    }

    /// The same key in the chat's page window goes to the chat.
    @Test func aKeyInAChatsPageWindowGoesToTheChat() throws {
        let facts = KeyFacts(pageInputPending: true, keyInOtherPage: true, pageID: KeyRouter.markdownPageID)
        #expect(KeyRouter(registry: Self.registry).decide(try Self.key("b", keyCode: 11), focus: Self.markdown,
                                                          keyWindow: .content, facts: facts) == .deliver)
    }

    /// A screen's primary input (Home's message box) never takes a key another page's window has.
    @Test func thePrimaryInputLeavesAKeyInAnotherPagesWindow() throws {
        let home = Self.focus(.conversation(pane: "pane_home", tab: "tab_home"))
        let router = KeyRouter(registry: Self.registry)
        let event = try Self.key("b", keyCode: 11)
        #expect(router.decide(event, focus: home, keyWindow: .content,
                              facts: KeyFacts(primaryInputReady: true, primaryInputClaimsKey: true)) == .primaryInput)
        #expect(router.decide(event, focus: home, keyWindow: .content,
                              facts: KeyFacts(primaryInputReady: true, primaryInputClaimsKey: true, keyInOtherPage: true)) == .deliver)
    }
}
