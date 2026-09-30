import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextTerminal
import Testing

/// Browser context chord resolution (focus.md section 5, "Browser
/// context"): Chrome's chords beat the Ghostty keybind fallback in a page,
/// the address bar and the find bar; cmux's own bindings still win first.
@MainActor
struct BrowserChordTableTests {
    typealias K = KeyInterceptionTests

    /// A router whose Ghostty config binds Ghostty's defaults
    /// `super+[` / `super+]` to `goto_split:previous` / `next` and the user's
    /// `cmd+ctrl+h` to `goto_split:left`.
    static func services() -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        let binds = [
            GhosttyHostKeybind(key: .unicode(UInt32(("[" as Unicode.Scalar).value)), modifiers: [.command], action: .gotoSplit(.previous)),
            GhosttyHostKeybind(key: .unicode(UInt32(("]" as Unicode.Scalar).value)), modifiers: [.command], action: .gotoSplit(.next)),
            GhosttyHostKeybind(key: .unicode(UInt32(("h" as Unicode.Scalar).value)), modifiers: [.command, .control], action: .gotoSplit(.left)),
            GhosttyHostKeybind(key: .unicode(UInt32(("y" as Unicode.Scalar).value)), modifiers: [.command], action: .toggleSplitZoom),
        ]
        services.keyRouter.ghosttyHostAction = { event in binds.first { $0.matches(event) }?.action }
        return services
    }

    static func bracket(_ key: String) throws -> NSEvent {
        try K.key(key, keyCode: key == "[" ? 33 : 30, [.command])
    }

    /// Cmd-[ in a page is Back: the registry's browser action, run by the
    /// window hook (WebKit, in-window) or Chromium's pre-key hook (page
    /// window). Both are `.browserPage` focus; neither lets Ghostty's
    /// `goto_split:previous` take the chord.
    @Test func commandBracketInAPageIsBack() throws {
        let services = Self.services()
        var ran: [ActionID] = []
        for id: ActionID in ["browserBack", "browserForward", "focusPreviousPane", "focusNextPane", "focusHistoryBack", "focusHistoryForward"] {
            services.registry.bind(id, invoke: { _ in ran.append(id) })
        }
        services.registry.context.insert(.browserFocused)
        for key in ["[", "]"] {
            let event = try Self.bracket(key)
            let candidate = try #require(services.keyRouter.candidate(for: event, focus: K.page))
            #expect(candidate.tier == .content)
            #expect(!KeyRouter.intercepts(candidate, focus: K.page, keyWindow: .content), "page window and WebKit alike")
            #expect(services.keyRouter.routeContentKeyEquivalent(event, focus: K.page))
        }
        #expect(ran == ["browserBack", "browserForward"])
    }

    /// In the address bar the field keeps Cmd-[ (no Back, no split).
    @Test func commandBracketInTheOmnibarStaysInTheField() throws {
        let services = Self.services()
        services.registry.context.insert(.browserFocused)
        let event = try Self.bracket("[")
        if let candidate = services.keyRouter.candidate(for: event, focus: K.omnibar) {
            #expect(!KeyRouter.intercepts(candidate, focus: K.omnibar, keyWindow: .content))
            if case .ghostty = candidate.source { Issue.record("Ghostty fallback in the omnibar") }
        }
        #expect(!services.keyRouter.routeContentKeyEquivalent(event, focus: K.omnibar))
    }

    /// In a terminal no registry browser action applies; the chord is never
    /// the Ghostty fallback there (the terminal runs its own keybind, so
    /// `super+[` is `goto_split:previous` unless cmux binds the chord).
    @Test func commandBracketInATerminalIsNotBack() throws {
        let services = Self.services()
        services.registry.context.insert(.terminalFocused)
        let event = try Self.bracket("[")
        let candidate = services.keyRouter.candidate(for: event, focus: K.terminal)
        #expect(candidate?.id != "browserBack")
        if let candidate, case .ghostty = candidate.source {
            #expect(!KeyRouter.intercepts(candidate, focus: K.terminal, keyWindow: .content), "the terminal runs its Ghostty keybind")
        }
    }

    /// Chrome chords without a cmux action (Cmd-Y, history) go
    /// to the page, never to a Ghostty keybind; chords neither defines
    /// (Cmd-Ctrl-H) still take the Ghostty fallback in a page.
    @Test func ghosttyFallbackOnlyForChordsNeitherDefines() throws {
        let services = Self.services()
        services.registry.context.insert(.browserFocused)
        let devtools = try K.key("y", keyCode: 16, [.command])
        #expect(BrowserChordTable.isChromeChord(devtools))
        for focus in [K.page, K.omnibar, K.find] {
            #expect(services.keyRouter.candidate(for: devtools, focus: focus) == nil)
        }
        #expect(services.keyRouter.candidate(for: devtools, focus: K.terminal)?.source == .ghostty(arguments: [:]))
        let user = try K.key("h", keyCode: 4, [.command, .control])
        #expect(!BrowserChordTable.isChromeChord(user))
        #expect(services.keyRouter.candidate(for: user, focus: K.page) == K.ghosttyFocusLeft)
    }

    @Test func shiftedChordsMatchTheirBase() throws {
        let event = try K.key("{", keyCode: 33, [.command, .shift])
        #expect(BrowserChordTable.isChromeChord(event))
    }
}
