import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// R65 (spec app-screens.md section 3): open a screen, type, and the text
/// lands in its primary input. When Home, an agent chat or an app screen
/// has the keyboard and none of its text fields has focus, a printable key
/// goes to the primary input (the first key is not lost); Command and
/// Control chords resolve first; a terminal, a web page and a focused text
/// field keep their keys.
@MainActor
struct KeyPrimaryInputTests {
    typealias M = KeyOwnershipMatrixTests
    typealias K = KeyInterceptionTests

    static let ready = KeyRouter.Facts(primaryInputReady: true)

    @Test func typingOnAnOpenScreenGoesToItsPrimaryInput() throws {
        let services = M.services()
        let router = services.keyRouter
        let letter = try K.key("h", keyCode: 4, [])
        let screens: [(String, FocusState)] = [
            ("Home", M.focused(M.homeKind, tab: "home-1")),
            ("agent chat", M.focused(.agent, tab: "local-agent:1")),
            ("App Store", M.focused(.page, tab: "local-page:app-store:1")),
        ]
        for (name, focus) in screens {
            #expect(router.decide(letter, focus: focus, keyWindow: .content, facts: Self.ready) == .primaryInput, "\(name)")
            // A text field of the screen has the keyboard: it keeps the key.
            #expect(router.decide(letter, focus: focus, keyWindow: .content, facts: KeyRouter.Facts()) == .deliver, "\(name) field")
            // Chords resolve first.
            let palette = try K.key("p", keyCode: 35, [.command, .shift])
            #expect(router.decide(palette, focus: focus, keyWindow: .content, facts: Self.ready) == .run(
                KeyRouter.Candidate(id: "commandPalette", tier: .system, source: .registry(argument: nil))), "\(name)")
        }
    }

    @Test func navigationKeysAndOtherSurfacesKeepTheirKeys() throws {
        let services = M.services()
        let router = services.keyRouter
        let home = M.focused(M.homeKind, tab: "home-1")
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        for event in [try K.key(up, keyCode: 126, [.function, .numericPad]), try K.key("\r", keyCode: 36, []),
                      try K.key("\t", keyCode: 48, []), try K.key("\u{1b}", keyCode: 53, []), try K.key("\u{7f}", keyCode: 51, [])] {
            #expect(router.decide(event, focus: home, keyWindow: .content, facts: Self.ready) == .deliver)
        }
        let letter = try K.key("h", keyCode: 4, [])
        for focus in [M.terminal, M.page] {
            #expect(router.decide(letter, focus: focus, keyWindow: .content, facts: Self.ready) == .deliver)
        }
        // An input method composing keeps every key.
        #expect(router.decide(letter, focus: home, keyWindow: .content,
                              facts: KeyRouter.Facts(hasMarkedText: true, primaryInputReady: true)) == .deliver)
    }
}
