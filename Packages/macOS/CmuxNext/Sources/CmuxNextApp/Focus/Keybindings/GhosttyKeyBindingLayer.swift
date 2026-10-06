import AppKit
import CmuxNextActions
import CmuxNextTerminal

/// The Ghostty config's keybinds as binding table entries (GHOSTTY-CONFIG,
/// plans/cmux-next/ghostty-config.md "Keybinds": cmux.json shortcuts > the
/// user's Ghostty keybinds in a focused terminal > cmux defaults > Ghostty
/// defaults).
///
/// Every routed keybind (`TerminalHostActionRoute`) of the loaded config is
/// a `.ghosttyFallback` entry: below every cmux entry, so it runs only where
/// no cmux binding claims the chord (in a terminal the terminal runs it, in
/// a page or the sidebar the routed action runs). A keybind that differs
/// from Ghostty's and cmux's defaults (`defaults`) is the user's: it is also
/// a `.ghostty` entry, above cmux's defaults, while a terminal has the
/// keyboard and is not in copy mode (copy mode takes every key before
/// Ghostty). Ghostty's reverse map gives one chord per action (the last
/// bound), so a default chord the user rebound to another action reads as
/// that action's default and stays below cmux's defaults; Ghostty actions
/// without a route are not in the table (the terminal still gets keys no
/// entry claims).
struct GhosttyKeyBindingLayer {
    /// The loaded config's routable keybinds (`GhosttyRuntime.hostKeybinds`).
    var binds: [GhosttyHostKeybind]
    /// The same read from a config without user files (`defaultHostKeybinds`).
    var defaults: [GhosttyHostKeybind]
    /// Table key names of physical keys (`KeyCodeLayout.currentKeyNames`).
    var keyNames: [UInt16: String]

    /// A terminal has the keyboard and Ghostty sees its keys.
    static let terminalFocused = WhenClause.and([
        .equals(KeyContext.surfaceKind, .string("terminal")), .not(.has(KeyContext.terminalCopyMode)),
    ])

    var entries: [KeyBinding] {
        var fallbacks: [KeyBinding] = []
        var terminal: [KeyBinding] = []
        for bind in binds {
            // Only Command and Control chords reach the dispatcher.
            guard let route = TerminalHostActionRoute.route(bind.action), let shortcut = shortcut(for: bind),
                  !shortcut.modifiers.isDisjoint(with: [.command, .control]) else { continue }
            fallbacks.append(KeyBinding(keys: [shortcut], command: route.id, arguments: route.arguments, source: .ghosttyFallback))
            if !defaults.contains(bind) {
                terminal.append(KeyBinding(keys: [shortcut], command: route.id, arguments: route.arguments, when: Self.terminalFocused,
                                           source: .ghostty))
            }
        }
        return fallbacks + terminal
    }

    /// The table key of a trigger: its codepoint, or the physical key's name.
    func shortcut(for bind: GhosttyHostKeybind) -> Shortcut? {
        switch bind.key {
        case .unicode(let scalar):
            UnicodeScalar(scalar).map { Shortcut(String(Character($0)), modifiers: bind.modifiers) }
        case .keyCode(let code):
            keyNames[code].map { Shortcut($0, modifiers: bind.modifiers) }
        }
    }
}

extension KeyRouter {
    /// Loads the user's Ghostty keybinds (`binds`, the loaded config) and
    /// Ghostty's own defaults (`defaults`, a config with no user files) into
    /// the registry's binding table.
    func loadGhosttyKeybinds(_ binds: [GhosttyHostKeybind], defaults: [GhosttyHostKeybind],
                             keyNames: [UInt16: String] = KeyCodeLayout.currentKeyNames()) {
        KeyBindingLoader(registry).loadGhostty(GhosttyKeyBindingLayer(binds: binds, defaults: defaults, keyNames: keyNames).entries)
    }
}

/// Keeps the binding table's Ghostty entries current: at launch, after
/// every Ghostty config change and after a keyboard layout change (physical
/// triggers name keys by what they type).
final class GhosttyKeybindSync {
    private weak var router: KeyRouter?
    private var layoutObserver: KeyboardLayoutObserver?

    init(router: KeyRouter) {
        self.router = router
    }

    func start() {
        let runtime = GhosttyRuntime.shared
        let previous = runtime.onConfigChange
        runtime.onConfigChange = { [weak self] in
            previous?()
            self?.load()
        }
        layoutObserver = KeyboardLayoutObserver { [weak self] in self?.load() }
        load()
    }

    private func load() {
        guard let router else { return }
        let runtime = GhosttyRuntime.shared
        router.loadGhosttyKeybinds(runtime.hostKeybinds, defaults: runtime.defaultHostKeybinds)
    }
}
