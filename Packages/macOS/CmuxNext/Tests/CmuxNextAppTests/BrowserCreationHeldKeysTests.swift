import AppKit
@testable import CmuxNextFocusUI
import Foundation
import Testing

/// A key the creation hold keeps for a new browser tab (Cmd-Shift-L, its stand-in focused) runs again into what has
/// the keyboard, its omnibar: it is never bound to the tab as a terminal's lane, which typed it into no terminal and
/// dropped it. A close of the stand-in still cancels the creation.
@MainActor @Suite struct BrowserCreationHeldKeysTests {
    private static func key(_ character: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 12))
    }

    private static func held(typesIntoTab: Bool) throws -> [CreationInputBuffer.HeldKey] {
        let buffer = CreationInputBuffer(began: .now)
        let ticket = buffer.open(generation: 1, tab: "pending_tab_omnibar", typesIntoTab: typesIntoTab)
        buffer.capture(try key("q"), focusedTab: "pending_tab_omnibar")
        buffer.resolve(ticket, awaitsFocus: true)
        return buffer.take(focused: nil) { _, _ in false }
    }

    @Test func aKeyHeldForANewBrowserTabRunsAgainIntoWhatHasTheKeyboard() throws {
        let keys = try Self.held(typesIntoTab: false)
        #expect(keys.count == 1)
        if case .run? = keys.first {} else { Issue.record("the key was not run again: \(keys)") }
        // A terminal's creation keeps its lane: its key is typed into that terminal.
        if case .type? = try Self.held(typesIntoTab: true).first {} else { Issue.record("a terminal's key lost its lane") }
    }

    @Test func aCloseOfTheNewBrowserTabStillCancelsItsCreation() {
        let buffer = CreationInputBuffer(began: .now)
        _ = buffer.open(generation: 1, tab: "pending_tab_omnibar", typesIntoTab: false)
        #expect(buffer.cancel(tab: "pending_tab_omnibar"))
        #expect(buffer.isResolved)
    }
}
