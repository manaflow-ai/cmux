import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTerminal
import Testing

/// Who owns a key-down in each surface kind (plans/cmux-next/keybindings.md
/// section 6): a cmux action, the focused surface (terminal, page, field),
/// or a panel over the window. Ctrl-Tab and Ctrl-Shift-Tab rows come first:
/// they must change tabs in every surface except a terminal (its Ghostty
/// keybind `ctrl+tab=next_tab` runs the same action), browser focus mode
/// (the page gets every non-system key) and the palette (its own keys).
@MainActor
struct KeyOwnershipMatrixTests {
    typealias K = KeyInterceptionTests
    typealias Pane = FocusTopology.Pane
    typealias Tab = FocusTopology.Tab

    // MARK: Surfaces

    struct Surface {
        var name: String
        var focus: FocusState
        var window: KeyRouter.KeyWindowKind = .content
        var facts = KeyOwnershipFacts()
    }

    /// One focused pane `a` whose selected tab `tab` has `kind`, with a
    /// second tab of the same kind (so next/previous tab has somewhere to go).
    static func focused(_ kind: FocusTopology.Kind, tab: String, target: FocusState.Target = .content) -> FocusState {
        var state = FocusState()
        state.windowKey = true
        state.appActive = true
        state.topology = FocusTopology(workspace: "w", panes: [
            Pane(id: "a", tabs: [Tab(id: tab, surface: "s-\(tab)", kind: kind), Tab(id: tab + "-2", surface: "s-\(tab)-2", kind: kind)], selected: tab),
        ])
        state.pane = "a"
        state.target = target
        return state
    }

    static var terminal: FocusState { focused(.terminal, tab: "t1") }
    static var page: FocusState { focused(.browser, tab: "b1") }

    static var surfaces: [Surface] {
        var focusMode = page
        focusMode.browserFocusMode = ["b1"]
        var palette = terminal
        palette.overlays = [.palette]
        return [
            Surface(name: "terminal", focus: terminal),
            Surface(name: "terminal alt screen", focus: terminal, facts: KeyOwnershipFacts(terminalAltScreen: true)),
            Surface(name: "terminal copy mode", focus: terminal, facts: KeyOwnershipFacts(terminalCopyMode: true)),
            Surface(name: "page (WebKit)", focus: page),
            Surface(name: "page (Chromium page window)", focus: page),
            // A Chromium pane's keys reach `CEFTab.keyRouter`, which runs this
            // same dispatcher for a key `sendEvent` did not decide.
            Surface(name: "page (Chromium, through CEFTab.keyRouter)", focus: page),
            Surface(name: "React page (cmux-page://settings/, WebKit)", focus: page),
            Surface(name: "React page (cmux-page://settings/, Chromium)", focus: page),
            Surface(name: "text field in a page", focus: page),
            Surface(name: "address bar", focus: focused(.browser, tab: "b1", target: .addressBar)),
            Surface(name: "find bar", focus: focused(.browser, tab: "b1", target: .findBar)),
            Surface(name: "browser focus mode", focus: focusMode),
            Surface(name: "agent chat composer", focus: focused(.agent, tab: "local-agent:1")),
            Surface(name: "Settings", focus: focused(.page, tab: "local-page:settings:1")),
            Surface(name: "App Store", focus: focused(.page, tab: "local-page:app-store:1")),
            Surface(name: "Home", focus: focused(homeKind, tab: "home-1")),
            Surface(name: "empty pane", focus: focused(.other, tab: "x1")),
            Surface(name: "sidebar", focus: focused(.terminal, tab: "t1", target: .sidebar(keyboard: false))),
            Surface(name: "sidebar search field", focus: focused(.terminal, tab: "t1", target: .sidebarField)),
            Surface(name: "terminal find field", focus: focused(.terminal, tab: "t1", target: .textField)),
            Surface(name: "palette open", focus: palette, window: .textPanel),
        ]
        // Diff and Markdown: cmux-next has no diff or Markdown viewer yet
        // (MiscHandlerStrings.diffViewer, .markdownViewer); their rows land
        // with the viewers.
    }

    // MARK: Keys

    static let pageUp = String(UnicodeScalar(NSPageUpFunctionKey)!)
    static let pageDown = String(UnicodeScalar(NSPageDownFunctionKey)!)

    static func tabKeys() throws -> [(name: String, event: NSEvent)] {
        [
            ("ctrl-tab", try K.key("\t", keyCode: 48, [.control])),
            ("ctrl-shift-tab", try K.key("\u{19}", keyCode: 48, [.control, .shift])),
            ("ctrl-pagedown", try K.key(pageDown, keyCode: 121, [.control, .function])),
            ("ctrl-pageup", try K.key(pageUp, keyCode: 116, [.control, .function])),
        ]
    }

    /// Expected owner per surface for ctrl-tab, ctrl-shift-tab,
    /// ctrl-pagedown, ctrl-pageup.
    static func expectedTabOwners(_ surface: String) -> [KeyOwner] {
        let switches: [KeyOwner] = [.action("nextSurface"), .action("prevSurface"), .action("nextSurface"), .action("prevSurface")]
        switch surface {
        // Ghostty's own `ctrl+tab=next_tab` (same action); the shell gets
        // Ctrl-PageDown/Up (no Ghostty default on macOS).
        case "terminal", "terminal alt screen": return [.surface, .surface, .surface, .surface]
        // Copy mode takes every other key; Ctrl-Tab must still change tabs.
        case "terminal copy mode": return [.action("nextSurface"), .action("prevSurface"), .surface, .surface]
        case "browser focus mode": return [.surface, .surface, .surface, .surface]
        case "palette open": return [.panel, .panel, .panel, .panel]
        default: return switches
        }
    }

    static func services() -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        // Ghostty's reverse map on macOS: one trigger per action, the last
        // one bound, so `next_tab` is `super+shift+]`, never `ctrl+tab`.
        let binds = [
            GhosttyHostKeybind(key: .unicode(UInt32(("]" as Unicode.Scalar).value)), modifiers: [.command, .shift], action: .gotoTab(.next)),
            GhosttyHostKeybind(key: .unicode(UInt32(("[" as Unicode.Scalar).value)), modifiers: [.command, .shift], action: .gotoTab(.previous)),
        ]
        services.keyRouter.ghosttyHostAction = { event in binds.first { $0.matches(event) }?.action }
        return services
    }

    // MARK: Ctrl-Tab rows

    @Test func ctrlTabAndCtrlShiftTabChangeTabsInEverySurface() throws {
        let services = Self.services()
        let keys = try Self.tabKeys()
        var failures: [String] = []
        for surface in Self.surfaces {
            let expected = Self.expectedTabOwners(surface.name)
            for (index, key) in keys.enumerated() {
                let owner = Self.owner(services, key.event, surface)
                if owner != expected[index] {
                    failures.append("\(surface.name) \(key.name): \(owner) != \(expected[index])")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) wrong owners:\n\(failures.joined(separator: "\n"))")
    }

    /// A React page (`cmux-page://<id>/`: Settings, History, App Store) is
    /// a web page (`surfaceKind == page`). It gets the keys the dispatcher
    /// delivers (arrows, Return, Escape, typing) and never handles a Command
    /// or Control chord itself: chords resolve in the dispatcher.
    @Test func reactPageGetsNavigationKeysAndChordsResolveInTheDispatcher() throws {
        let services = Self.services()
        let reactPage = Surface(name: "React page (cmux-page://settings/)", focus: Self.page)
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let delivered: [(String, NSEvent)] = [
            ("up", try K.key(up, keyCode: 126, [.function, .numericPad])),
            ("down", try K.key(down, keyCode: 125, [.function, .numericPad])),
            ("return", try K.key("\r", keyCode: 36, [])),
            ("escape", try K.key("\u{1b}", keyCode: 53, [])),
            ("typing", try K.key("a", keyCode: 0, [])),
        ]
        for (name, event) in delivered {
            #expect(Self.owner(services, event, reactPage) == .surface, "\(name)")
        }
        #expect(Self.owner(services, try K.key("p", keyCode: 35, [.command, .shift]), reactPage) == .action("commandPalette"))
        #expect(Self.owner(services, try K.key("w", keyCode: 13, [.command]), reactPage) == .action("closeTab"))
        #expect(Self.owner(services, try K.key("\t", keyCode: 48, [.control]), reactPage) == .action("nextSurface"))
    }

    /// Step 1: while an input method composes (marked text), every key it
    /// can use reaches it (Ctrl-Tab too); a Command chord still resolves.
    @Test func inputMethodKeepsItsKeysAndCommandChordsStillResolve() throws {
        let services = Self.services()
        let composing = KeyRouter.Facts(hasMarkedText: true)
        let agent = Self.focused(.agent, tab: "local-agent:1")
        let router = services.keyRouter!
        #expect(router.decide(try K.key("\t", keyCode: 48, [.control]), focus: agent, keyWindow: .content, facts: composing) == .deliver)
        #expect(router.decide(try K.key("k", keyCode: 40, [.control]), focus: agent, keyWindow: .content, facts: composing) == .deliver)
        guard case .run(let candidate) = router.decide(try K.key("w", keyCode: 13, [.command]), focus: agent, keyWindow: .content,
                                                       facts: composing) else {
            Issue.record("Cmd-W did not resolve while composing")
            return
        }
        #expect(candidate.id == "closeTab")
    }

    /// The registry decides with the focus of the window the key goes to,
    /// never with the process-wide context another window published: Cmd-R
    /// in a page is Reload even while the global context still says
    /// terminal (focus.md R10).
    @Test func resolutionUsesTheKeyWindowsFocusNotTheGlobalContext() throws {
        let services = Self.services()
        for id: ActionID in ["browserReload", "renameTab"] { services.registry.bind(id, invoke: { _ in }) }
        services.registry.context = [.terminalFocused]
        let reload = try K.key("r", keyCode: 15, [.command])
        #expect(services.keyRouter.candidate(for: reload, focus: Self.page)?.id == "browserReload")
        services.registry.context = [.browserFocused]
        #expect(services.keyRouter.candidate(for: reload, focus: Self.terminal)?.id != "browserReload")
    }

    // MARK: Every default binding

    /// Every default single-key Command or Control binding keeps today's
    /// owner in every surface whose context it needs: the most specific
    /// runnable default on that key (catalog order breaks a tie) runs when
    /// its tier may take the key from this focus, else the surface gets the
    /// key (Cmd-Shift-R in the address bar is the page's hard reload, which
    /// a text field keeps). Guards the dispatcher refactor: no default changes.
    /// A more specific default meant for this context that cannot run makes
    /// the key the surface's (R88).
    @Test func everyDefaultBindingKeepsItsOwnerInEverySurface() throws {
        let services = Self.services()
        let registry = services.registry
        let surfaces = Self.surfaces.filter { $0.window == .content && $0.facts == KeyOwnershipFacts() }
        var byKey: [Shortcut: [ActionDescriptor]] = [:]
        for descriptor in registry.descriptors where registry.effectiveChord(for: descriptor.id) == nil
            && descriptor.shortcutFamily == nil {
            guard let shortcut = registry.effectiveShortcut(for: descriptor.id), KeyRouter.isChord(shortcut.modifiers) else { continue }
            byKey[shortcut, default: []].append(descriptor)
        }
        var failures: [String] = []
        var checked = 0
        for (shortcut, descriptors) in byKey {
            guard let event = KeyEvents.event(for: shortcut) else { continue }
            for surface in surfaces {
                let bits = Self.contextBits(surface.focus, base: registry.context)
                registry.context = bits
                let applicable = descriptors.filter { bits.isSuperset(of: $0.requires) }
                let runnable = applicable.filter { registry.canPerform($0.id) }
                guard var top = runnable.first else { continue }
                for descriptor in runnable.dropFirst()
                where descriptor.requires.rawValue.nonzeroBitCount > top.requires.rawValue.nonzeroBitCount { top = descriptor }
                // R88: a more specific default meant for this context that cannot run ends the
                // search; the key never falls through to a less specific one (Cmd-R in a page
                // without a runnable Reload no longer renames the tab).
                let blocked = applicable.contains {
                    !$0.requires.isEmpty && !registry.canPerform($0.id)
                        && $0.requires.rawValue.nonzeroBitCount > top.requires.rawValue.nonzeroBitCount
                }
                let expected: KeyOwner = !blocked && KeyRouter.allows(registry.keyTier(for: top.id), id: top.id, focus: surface.focus)
                    ? .action(top.id) : .surface
                checked += 1
                let owner = Self.owner(services, event, surface)
                if owner != expected {
                    failures.append("\(shortcut.displayString) in \(surface.name): \(owner) != \(expected)")
                }
            }
        }
        #expect(checked > 100, "only \(checked) rows checked")
        #expect(failures.isEmpty, "\(failures.count) wrong owners:\n\(failures.joined(separator: "\n"))")
    }

    // MARK: Owner of a key-down

    /// The registry context bits the window's focus publishes
    /// (`FocusEffectApplier.publish`), over the focus-independent bits.
    static func contextBits(_ focus: FocusState, base: ActionContext) -> ActionContext {
        var bits = base
        bits.subtract(ActionContext.focusBits)
        let context = focus.context
        if context.terminal { bits.insert(.terminalFocused) }
        if context.browser { bits.insert(.browserFocused) }
        if context.agent { bits.insert(.agentPaneFocused) }
        if case .addressBar = focus.resolved { bits.insert(.omnibarFocused) }
        return bits
    }

    /// The owner the key dispatcher gives `event` in `surface`.
    static func owner(_ services: AppServices, _ event: NSEvent, _ surface: Surface) -> KeyOwner {
        let facts = KeyRouter.Facts(terminalCopyMode: surface.facts.terminalCopyMode)
        switch services.keyRouter.decide(event, focus: surface.focus, keyWindow: surface.window, facts: facts) {
        case .run(let candidate): return .action(candidate.id)
        case .deliver: return .surface
        case .consume: return .consumed
        case .panel: return .panel
        case .primaryInput: return .primaryInput
        case .typeAhead: return .typeAhead
        }
    }

    /// The tab kind a Home conversation tab has in the focus topology.
    static var homeKind: FocusTopology.Kind { .of(.conversation, isFrontendOwned: false) }
}
