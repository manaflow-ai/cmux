import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextTerminal
import Testing

/// The app-wide key interceptor (`CmuxApplication.sendEvent` ->
/// `KeyRouter.interceptKeyDown`): which focus targets let tier 0 and tier 1
/// shortcuts through before the focused view or page window, and that the
/// per-window hooks never run them a second time (plans/cmux-next/focus.md 5).
@MainActor
struct KeyInterceptionTests {
    typealias Candidate = KeyRouter.Candidate

    static let focusLeft = Candidate(id: "focusLeft", tier: .navigation, source: .registry(argument: nil))
    static let ghosttyFocusLeft = Candidate(id: "focusLeft", tier: .navigation, source: .ghostty(arguments: [:]))
    static let palette = Candidate(id: "commandPalette", tier: .system, source: .registry(argument: nil))
    static let reload = Candidate(id: "browserReload", tier: .content, source: .registry(argument: nil))

    static let terminal = FocusReducerTests.loaded()
    static let page = FocusReducer.reduce(terminal, .focusPane("b", source: .mouse)).0
    static let omnibar = FocusReducer.reduce(page, .focusTarget(.addressBar, source: .keyboard)).0
    static let find = FocusReducer.reduce(page, .focusTarget(.findBar, source: .keyboard)).0
    static let focusMode = FocusReducer.reduce(page, .toggleBrowserFocusMode(tab: nil)).0
    static let paletteOpen = FocusReducer.reduce(terminal, .overlayOpened(.palette)).0
    static let sheetOpen = FocusReducer.reduce(terminal, .overlayOpened(.sheet)).0

    @Test func focusTargetsAreWhatTheTableAssumes() {
        #expect(Self.terminal.resolved == .terminal(pane: "a", tab: "t1"))
        #expect(Self.page.resolved == .browserPage(pane: "b", tab: "b1"))
        #expect(Self.omnibar.resolved == .addressBar(pane: "b", tab: "b1"))
        #expect(Self.find.resolved == .findBar(pane: "b", tab: "b1"))
        #expect(Self.focusMode.isBrowserFocusModeActive)
    }

    /// Cmd-Opt-Left (registry, tier 1) per focus target. A WebKit page is
    /// the cmux window's own first responder and a Chromium page is a child
    /// window that is key: both are `.content` key windows whose focus is
    /// the page, so both intercept.
    @Test func navigationChordPerFocusTarget() {
        let cases: [(String, FocusState, KeyRouter.KeyWindowKind, Bool)] = [
            ("terminal", Self.terminal, .content, true),
            ("WebKit page", Self.page, .content, true),
            ("Chromium page window", Self.page, .content, true),
            ("omnibar", Self.omnibar, .content, true),
            ("find bar", Self.find, .content, true),
            ("browser focus mode", Self.focusMode, .content, false),
            ("palette panel", Self.paletteOpen, .textPanel, false),
            ("sheet", Self.sheetOpen, .textPanel, false),
            ("another app's window", Self.terminal, .other, false),
        ]
        for (name, focus, window, expected) in cases {
            #expect(KeyRouter.intercepts(Self.focusLeft, focus: focus, keyWindow: window) == expected, "\(name)")
        }
    }

    /// A Ghostty `goto_split` keybind (Cmd-Ctrl-H) runs app-wide except
    /// when a terminal has the keyboard, which runs its own keybinds.
    @Test func ghosttyKeybindPerFocusTarget() {
        #expect(!KeyRouter.intercepts(Self.ghosttyFocusLeft, focus: Self.terminal, keyWindow: .content))
        #expect(KeyRouter.intercepts(Self.ghosttyFocusLeft, focus: Self.page, keyWindow: .content))
        #expect(KeyRouter.intercepts(Self.ghosttyFocusLeft, focus: Self.omnibar, keyWindow: .content))
        #expect(KeyRouter.intercepts(Self.ghosttyFocusLeft, focus: Self.find, keyWindow: .content))
        #expect(!KeyRouter.intercepts(Self.ghosttyFocusLeft, focus: Self.focusMode, keyWindow: .content))
        #expect(!KeyRouter.intercepts(Self.ghosttyFocusLeft, focus: Self.paletteOpen, keyWindow: .textPanel))
    }

    @Test func systemRunsInFocusModeAndContentIsNeverIntercepted() {
        #expect(KeyRouter.intercepts(Self.palette, focus: Self.focusMode, keyWindow: .content))
        #expect(KeyRouter.intercepts(Self.palette, focus: Self.omnibar, keyWindow: .content))
        #expect(!KeyRouter.intercepts(Self.palette, focus: Self.paletteOpen, keyWindow: .textPanel), "the palette handles its own keys")
        for focus in [Self.terminal, Self.page, Self.omnibar] {
            #expect(!KeyRouter.intercepts(Self.reload, focus: focus, keyWindow: .content), "tier 2 runs in the window or page hook")
        }
    }

    @Test func onlyCommandAndControlChordsAreCandidates() {
        #expect(KeyRouter.isChord([.command, .option]))
        #expect(KeyRouter.isChord([.control]))
        #expect(!KeyRouter.isChord([.option]))
        #expect(!KeyRouter.isChord([.shift]))
        #expect(!KeyRouter.isChord([]))
    }

    // MARK: Candidates from real events

    static func key(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    static let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)

    @Test func commandOptionLeftResolvesToFocusLeftForEveryTarget() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let event = try Self.key(Self.left, keyCode: 123, [.command, .option, .numericPad, .function])
        for focus in [Self.terminal, Self.page, Self.omnibar, Self.find] {
            let candidate = try #require(services.keyRouter.candidate(for: event, focus: focus))
            #expect(candidate.id == "focusLeft")
            #expect(candidate.tier == .navigation)
            #expect(KeyRouter.intercepts(candidate, focus: focus, keyWindow: .content))
        }
    }

    @Test func ghosttyKeybindBecomesTheRoutedRegistryAction() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let router = services.keyRouter
        // A chord no cmux default binds (Ctrl-Cmd-H/J/K/L focus panes).
        let bind = GhosttyHostKeybind(key: .unicode(UInt32(("b" as Unicode.Scalar).value)), modifiers: [.command, .control],
                                      action: .gotoSplit(.left))
        router.loadGhosttyKeybinds([bind], defaults: [])
        let chord = try Self.key("b", keyCode: 11, [.command, .control])
        let candidate = try #require(router.candidate(for: chord, focus: Self.page))
        #expect(candidate == Self.ghosttyFocusLeft)
        #expect(router.candidate(for: try Self.key("b", keyCode: 11, [.command]), focus: Self.page)?.source != .ghostty(arguments: [:]))
    }

    /// The window and Chromium hooks run tier 2 only, so a tier 1 chord the
    /// interceptor declined (browser focus mode) never runs there either.
    @Test func windowHookRunsContentTierOnly() throws {
        let services = ActionBindingCoverageTests.boundServices()
        var ran: [ActionID] = []
        services.registry.bind("focusLeft", invoke: { _ in ran.append("focusLeft") })
        let event = try Self.key(Self.left, keyCode: 123, [.command, .option, .numericPad, .function])
        #expect(!services.keyRouter.routeContentKeyEquivalent(event, focus: Self.focusMode))
        #expect(!services.keyRouter.routeContentKeyEquivalent(event, focus: Self.page))
        #expect(ran.isEmpty)
    }

    /// cx-6so.46: with the palette open over a terminal, AppKit offers the
    /// palette's unhandled Cmd-K to the main window behind it too. The
    /// palette keeps the terminal's context bits (its commands act on that
    /// terminal), so the window hook resolved Cmd-K to Clear Screen and
    /// Scrollback and cleared the terminal under the palette.
    @Test func windowHookRunsNothingWhileAnOverlayHasTheKeys() throws {
        let services = ActionBindingCoverageTests.boundServices()
        var ran: [ActionID] = []
        services.registry.bind("terminal.clear", invoke: { _ in ran.append("terminal.clear") })
        let commandK = try Self.key("k", keyCode: 40, [.command])
        #expect(services.keyRouter.routeContentKeyEquivalent(commandK, focus: Self.terminal), "control: Cmd-K clears a focused terminal")
        #expect(ran == ["terminal.clear"])
        ran.removeAll()
        for overlay in [Self.paletteOpen, Self.sheetOpen] {
            #expect(!services.keyRouter.routeContentKeyEquivalent(commandK, focus: overlay))
        }
        #expect(ran.isEmpty, "Cmd-K under the palette ran \(ran)")
    }

    @Test func ghosttyTriggersMatchLikeGhostty() {
        let unicode = GhosttyHostKeybind(key: .unicode(104), modifiers: [.command, .control], action: .gotoSplit(.left))
        #expect(unicode.matches(keyCode: 4, unshifted: "h", modifiers: [.command, .control]))
        #expect(unicode.matches(keyCode: 4, unshifted: "H", modifiers: [.command, .control, .capsLock]))
        #expect(!unicode.matches(keyCode: 4, unshifted: "h", modifiers: [.command, .control, .shift]))
        #expect(!unicode.matches(keyCode: 38, unshifted: "j", modifiers: [.command, .control]))
        let physical = GhosttyHostKeybind(key: .keyCode(123), modifiers: [.command, .option], action: .gotoSplit(.left))
        #expect(physical.matches(keyCode: 123, unshifted: Self.left, modifiers: [.command, .option, .numericPad, .function]))
        #expect(!physical.matches(keyCode: 124, unshifted: nil, modifiers: [.command, .option]))
    }
}
