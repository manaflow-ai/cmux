import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextFocus
import Testing

/// Browser focus mode's exit, ported from classic cmux (Lawrence 2026-10-20: "Chrome Classic
/// has a feature where you can focus inside of a browser. We should have the same feature.").
/// Classic `BrowserPanel.handleBrowserFocusModeKeyEvent`: the first plain Escape reaches the page
/// and arms the exit, a second within 1.6 s leaves focus mode; repeats never count.
@MainActor @Suite struct BrowserFocusModeEscapeExitTests {
    static let registry = ActionRegistry.standard()

    static func escape(at timestamp: TimeInterval, _ modifiers: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false,
                       keyCode: UInt16 = 53) throws -> NSEvent {
        let characters = keyCode == 53 ? "\u{1b}" : "a"
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                             windowNumber: 0, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: keyCode))
    }

    static func focus(focusMode: Bool, tab: String = "tab_page") -> FocusState {
        var focus = FocusState()
        focus.resolved = .browserPage(pane: "pane_page", tab: tab)
        if focusMode {
            focus.browserFocusMode = [tab]
            focus.isBrowserFocusModeActive = true
        }
        return focus
    }

    @Test func escEscLeavesFocusMode() throws {
        let router = KeyRouter(registry: Self.registry)
        let focus = Self.focus(focusMode: true)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10), focus: focus) == .forwardToPage)
        #expect(router.focusModeEscape.armedTab == "tab_page")
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10.5), focus: focus) == .exit(tab: "tab_page"))
        #expect(router.focusModeEscape.armedTab == nil)
    }

    @Test func lateSecondEscapeRearmsInsteadOfExiting() throws {
        let router = KeyRouter(registry: Self.registry)
        let focus = Self.focus(focusMode: true)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10), focus: focus) == .forwardToPage)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 12), focus: focus) == .forwardToPage)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 13), focus: focus) == .exit(tab: "tab_page"))
    }

    @Test func otherKeyDisarms() throws {
        let router = KeyRouter(registry: Self.registry)
        let focus = Self.focus(focusMode: true)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10), focus: focus) == .forwardToPage)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10.2, keyCode: 0), focus: focus) == .pass)
        #expect(router.focusModeEscape.armedTab == nil)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10.4), focus: focus) == .forwardToPage)
    }

    @Test func heldEscapeNeverCountsAsSecondPress() throws {
        let router = KeyRouter(registry: Self.registry)
        let focus = Self.focus(focusMode: true)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10), focus: focus) == .forwardToPage)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10.1, repeat: true), focus: focus) == .consume)
        // The same key-down seen twice (two hooks) is one press.
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10), focus: focus) == .consume)
        #expect(router.focusModeEscape.armedTab == "tab_page")
    }

    @Test func escapeOutsideFocusModeIsUntouched() throws {
        let router = KeyRouter(registry: Self.registry)
        let focus = Self.focus(focusMode: false)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10), focus: focus) == .pass)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10.2), focus: focus) == .pass)
    }

    @Test func modifiedEscapeIsNotTheGesture() throws {
        let router = KeyRouter(registry: Self.registry)
        let focus = Self.focus(focusMode: true)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10, [.shift]), focus: focus) == .pass)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10.2, [.shift]), focus: focus) == .pass)
    }

    @Test func armedExitBelongsToOneTab() throws {
        let router = KeyRouter(registry: Self.registry)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10), focus: Self.focus(focusMode: true, tab: "tab_a")) == .forwardToPage)
        #expect(router.focusModeEscapeOutcome(try Self.escape(at: 10.3), focus: Self.focus(focusMode: true, tab: "tab_b")) == .forwardToPage)
        #expect(router.focusModeEscape.armedTab == "tab_b")
    }
}
