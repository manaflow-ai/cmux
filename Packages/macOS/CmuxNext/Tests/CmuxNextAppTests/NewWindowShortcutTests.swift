import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// Lawrence 2026-10-07: "cmd shift n is new window not incognito".
/// Shift-Cmd-N runs New Window and Option-Shift-Cmd-N runs New Incognito
/// Window, from every focus: the app's key router (`interceptKeyDown`) and
/// a Chromium page's pre-key hook (`browserTab(_:keyEquivalent:)`) both
/// call the same dispatcher, `KeyRouter.decide`, with the page's focus.
@MainActor
struct NewWindowShortcutTests {
    typealias K = KeyInterceptionTests

    /// The keys as AppKit delivers them on a US layout: Shift keeps "N" in
    /// `charactersIgnoringModifiers`; Option-Shift-N types "˜".
    static func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: "N", isARepeat: false, keyCode: 45))
    }

    static func shiftCmdN() throws -> NSEvent { try key("N", [.command, .shift]) }
    static func optShiftCmdN() throws -> NSEvent { try key("˜", [.command, .option, .shift]) }

    static func ranAction(_ decision: KeyRouter.Decision) -> ActionID? {
        if case .run(let candidate) = decision { return candidate.id }
        return nil
    }

    /// Terminal, page (WebKit, or a Chromium page window), address bar,
    /// find bar and browser focus mode.
    static let focuses: [(String, FocusState)] = [
        ("terminal", K.terminal), ("page", K.page), ("address bar", K.omnibar), ("find bar", K.find), ("browser focus mode", K.focusMode),
    ]

    @Test func shiftCommandNIsNewWindowAndOptionShiftCommandNIsIncognito() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let router: KeyRouter = services.keyRouter
        for (name, focus) in Self.focuses {
            services.registry.context = focus.resolved == K.terminal.resolved ? [.terminalFocused] : [.browserFocused]
            #expect(Self.ranAction(router.decide(try Self.shiftCmdN(), focus: focus, keyWindow: .content)) == "newWindow", "\(name)")
            #expect(Self.ranAction(router.decide(try Self.optShiftCmdN(), focus: focus, keyWindow: .content)) == "newIncognitoWindow",
                    "\(name)")
        }
    }

    /// Both chords are cmux shortcuts, so a Chromium page never sees them
    /// (Chromium's own Shift-Cmd-N is New Incognito Window).
    @Test func aPageNeverGetsEitherChord() throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.registry.context = [.browserFocused]
        for event in [try Self.shiftCmdN(), try Self.optShiftCmdN()] {
            let candidate = try #require(services.keyRouter.candidate(for: event, focus: K.page))
            #expect(KeyRouter.intercepts(candidate, focus: K.page, keyWindow: .content))
            #expect(KeyRouter.intercepts(candidate, focus: K.focusMode, keyWindow: .content), "system actions beat browser focus mode")
        }
    }

    /// Both stay editable: a user binding moves the chord, and the old
    /// chord no longer opens a window.
    @Test func bothChordsAreEditable() throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.registry.context = [.browserFocused]
        services.registry.setShortcutOverride(nil, for: "newWindow")
        services.registry.setShortcutOverride(Shortcut("n", modifiers: [.command, .shift]), for: "newIncognitoWindow")
        #expect(Self.ranAction(services.keyRouter.decide(try Self.shiftCmdN(), focus: K.page, keyWindow: .content)) == "newIncognitoWindow")
        #expect(Self.ranAction(services.keyRouter.decide(try Self.optShiftCmdN(), focus: K.page, keyWindow: .content)) == nil)
    }
}
