import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextTerminal
import Testing

/// Browser context chord resolution (focus.md section 5, "Browser
/// context"): browser chords beat the Ghostty keybind fallback in a page,
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
            // A chord no cmux default binds (Ctrl-Cmd-H/J/K/L resize panes since #17281).
            GhosttyHostKeybind(key: .unicode(UInt32(("b" as Unicode.Scalar).value)), modifiers: [.command, .control], action: .gotoSplit(.left)),
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

    /// Browser chords without a cmux action (Cmd-Shift-J, downloads) go
    /// to the page, never to a Ghostty keybind; chords neither defines
    /// (Cmd-Ctrl-H) still take the Ghostty fallback in a page.
    @Test func ghosttyFallbackOnlyForChordsNeitherDefines() throws {
        let services = Self.services()
        services.registry.context.insert(.browserFocused)
        let devtools = try K.key("j", keyCode: 38, [.command, .shift])
        #expect(BrowserChordTable.isChromeChord(devtools))
        for focus in [K.page, K.omnibar, K.find] {
            #expect(services.keyRouter.candidate(for: devtools, focus: focus) == nil)
        }
        // Cmd-Y is Show History in a page (history.md 5.1).
        let history = try K.key("y", keyCode: 16, [.command])
        #expect(services.keyRouter.candidate(for: history, focus: K.page)?.id == "browserShowHistory")
        // In a terminal (no browser context) the terminal's Ghostty keybind runs.
        services.registry.context.remove(.browserFocused)
        services.registry.context.insert(.terminalFocused)
        #expect(services.keyRouter.candidate(for: history, focus: K.terminal)?.source == .ghostty(arguments: [:]))
        services.registry.context.remove(.terminalFocused)
        services.registry.context.insert(.browserFocused)
        let user = try K.key("b", keyCode: 11, [.command, .control])
        #expect(!BrowserChordTable.isChromeChord(user))
        #expect(services.keyRouter.candidate(for: user, focus: K.page) == K.ghosttyFocusLeft)
    }

    static let pageUp = String(UnicodeScalar(NSPageUpFunctionKey)!)
    static let pageDown = String(UnicodeScalar(NSPageDownFunctionKey)!)

    /// The browser tab-switching chords as AppKit delivers them: Ctrl-Tab,
    /// Ctrl-Shift-Tab (Shift turns Tab into back-tab, U+0019), and
    /// Ctrl-PageDown / Ctrl-PageUp (function keys; Ctrl-Fn-Down/Up on a
    /// laptop keyboard).
    static func tabSwitchChords() throws -> [(name: String, event: NSEvent, action: ActionID)] {
        [
            ("ctrl-tab", try K.key("\t", keyCode: 48, [.control]), "nextSurface"),
            ("ctrl-shift-tab", try K.key("\u{19}", keyCode: 48, [.control, .shift]), "prevSurface"),
            ("ctrl-pagedown", try K.key(pageDown, keyCode: 121, [.control, .function]), "nextSurface"),
            ("ctrl-pageup", try K.key(pageUp, keyCode: 116, [.control, .function]), "prevSurface"),
        ]
    }

    /// Ctrl-Tab and its siblings switch cmux tabs in a page, the omnibar
    /// and the find bar, whatever the user's Ghostty
    /// keybinds say (this router binds none for them). They are tier 1, so
    /// the app-wide interceptor runs them before Chromium or a field sees
    /// the key.
    @Test func tabSwitchChordsSwitchCmuxTabsInABrowserContext() throws {
        let services = Self.services()
        var ran: [ActionID] = []
        for id: ActionID in ["nextSurface", "prevSurface"] {
            services.registry.bind(id, invoke: { _ in ran.append(id) })
        }
        services.registry.context.insert(.browserFocused)
        for chord in try Self.tabSwitchChords() {
            #expect(BrowserChordTable.isChromeChord(chord.event), "\(chord.name) is a browser chord")
            for focus in [K.page, K.omnibar, K.find] {
                let candidate = try #require(services.keyRouter.candidate(for: chord.event, focus: focus), "\(chord.name)")
                #expect(candidate.id == chord.action, "\(chord.name)")
                #expect(candidate.tier == .navigation, "\(chord.name)")
                #expect(KeyRouter.intercepts(candidate, focus: focus, keyWindow: .content), "\(chord.name) beats the page and fields")
            }
            // Browser focus mode: the page gets every non-system chord.
            if let candidate = services.keyRouter.candidate(for: chord.event, focus: K.focusMode) {
                #expect(!KeyRouter.intercepts(candidate, focus: K.focusMode, keyWindow: .content))
            }
        }
    }

    /// In a terminal the chords stay the terminal's (its own Ghostty
    /// keybinds, `ctrl+tab=next_tab` by default), not a cmux shortcut.
    @Test func tabSwitchChordsInATerminalAreTheTerminals() throws {
        let services = Self.services()
        services.registry.context.insert(.terminalFocused)
        for chord in try Self.tabSwitchChords() {
            #expect(services.keyRouter.candidate(for: chord.event, focus: K.terminal) == nil, "\(chord.name)")
        }
    }

    /// Unbinding the action in cmux.json also removes its browser chord aliases:
    /// the chord goes to the page.
    @Test func unboundTabActionLeavesTheChordToThePage() throws {
        let services = Self.services()
        services.registry.context.insert(.browserFocused)
        services.registry.setShortcutOverride(nil, for: "nextSurface")
        let ctrlTab = try K.key("\t", keyCode: 48, [.control])
        #expect(services.keyRouter.candidate(for: ctrlTab, focus: K.page) == nil)
    }

    @Test func shiftedChordsMatchTheirBase() throws {
        let event = try K.key("{", keyCode: 33, [.command, .shift])
        #expect(BrowserChordTable.isChromeChord(event))
    }
}
