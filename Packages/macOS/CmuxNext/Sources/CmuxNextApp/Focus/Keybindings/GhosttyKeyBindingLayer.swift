import AppKit
import CmuxNextActions
import CmuxNextTerminal

/// The Ghostty config's keybinds as binding table entries (GHOSTTY-CONFIG,
/// plans/cmux-next/ghostty-config.md "Keybinds"; PANE-FOCUS-RESIZE-KEYS-AND-
/// GHOSTTY-KEYBINDS: cmux.json shortcuts > the user's Ghostty keybinds >
/// cmux defaults > Ghostty defaults, in every surface).
///
/// Every routed keybind (`TerminalHostActionRoute`) of the loaded config is
/// a `.ghosttyFallback` entry: below every cmux entry, so it runs only where
/// no cmux binding claims the chord (in a terminal the terminal runs it, in
/// a page or the sidebar the routed action runs). A keybind that differs
/// from Ghostty's and cmux's defaults (`defaults`) is the user's: it is also
/// a `.ghostty` entry, above cmux's defaults everywhere (a focused terminal
/// runs it itself; elsewhere, and in copy mode, the routed action runs).
/// Ghostty's reverse map gives one chord per action (the last bound), so a
/// default chord the user rebound to another action reads as that action's
/// default and stays below cmux's defaults; Ghostty actions without a route
/// are not entries, but a key the user's config binds to one (or unbinds)
/// is a claim (`GhosttyKeyClaims`): no cmux default runs on it.
struct GhosttyKeyBindingLayer {
    /// The loaded config's routable keybinds (`GhosttyRuntime.hostKeybinds`).
    var binds: [GhosttyHostKeybind]
    /// The same read from a config without user files (`defaultHostKeybinds`).
    var defaults: [GhosttyHostKeybind]
    /// Table key names of physical keys (`KeyCodeLayout.currentKeyNames`).
    var keyNames: [UInt16: String]

    /// A terminal has the keyboard and Ghostty sees its keys (the dispatcher
    /// delivers a Ghostty entry's key to the terminal then).
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
                terminal.append(KeyBinding(keys: [shortcut], command: route.id, arguments: route.arguments, source: .ghostty))
            }
        }
        return fallbacks + terminal
    }

    /// The probe Ghostty's binding set matches for a table key: the physical
    /// key named `shortcut.key` and the codepoint it types (nil: no key).
    static func probe(for shortcut: Shortcut, keyNames: [UInt16: String]) -> GhosttyKeyProbe? {
        guard let code = keyNames.filter({ $0.value == shortcut.key }).keys.min() else { return nil }
        let scalars = shortcut.key.unicodeScalars
        // Function keys (arrows, Home) type nothing: Ghostty matches them by the physical key.
        let typed = scalars.count == 1 && !(0xF700...0xF8FF).contains(scalars.first?.value ?? 0) ? scalars.first?.value ?? 0 : 0
        return GhosttyKeyProbe(keyCode: code, unshifted: typed, modifiers: shortcut.modifiers)
    }

    /// The single Command or Control keys of the table's default entries
    /// (and of those a claim took out), each once.
    static func defaultKeys(_ table: KeyBindingTable) -> [Shortcut] {
        var seen = Set<Shortcut>()
        return (table.entries + table.claimedByGhostty).compactMap { entry -> Shortcut? in
            guard entry.source == .default, entry.keys.count == 1, let key = entry.keys.first,
                  !key.modifiers.isDisjoint(with: [.command, .control]), seen.insert(key).inserted else { return nil }
            return key
        }
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
    func loadGhosttyKeybinds(_ binds: [GhosttyHostKeybind], defaults: [GhosttyHostKeybind], claims: [Shortcut] = [],
                             keyNames: [UInt16: String] = KeyCodeLayout.currentKeyNames()) {
        KeyBindingLoader(registry).loadGhostty(GhosttyKeyBindingLayer(binds: binds, defaults: defaults, keyNames: keyNames).entries,
                                               claims: claims)
    }
}

/// Keeps the binding table's Ghostty entries current: at launch, after
/// every Ghostty config change and after a keyboard layout change (physical
/// triggers name keys by what they type).
final class GhosttyKeybindSync {
    private weak var router: KeyRouter?
    private var layoutObserver: KeyboardLayoutObserver?
    private var claimsTask: Task<Void, Never>?

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

    /// Loads the routed keybinds at once (keeping the last claims), then the
    /// claims once the config files are read off the main actor; a newer
    /// load cancels an older one's claims.
    private func load() {
        guard let router else { return }
        let runtime = GhosttyRuntime.shared
        let keyNames = KeyCodeLayout.currentKeyNames()
        let binds = runtime.hostKeybinds, defaults = runtime.defaultHostKeybinds
        router.loadGhosttyKeybinds(binds, defaults: defaults, claims: router.registry.keyBindingLayers.ghosttyClaims, keyNames: keyNames)
        let files = runtime.loadedConfigFiles
        claimsTask?.cancel()
        claimsTask = Task { [weak self] in
            let texts = await GhosttyRuntime.configTexts(files)
            guard !Task.isCancelled, let router = self?.router else { return }
            // The keys cmux has defaults on, asked of the user's Ghostty config.
            let probes = GhosttyKeyBindingLayer.defaultKeys(RegistryKeyBindings(router.registry).table).compactMap { key in
                GhosttyKeyBindingLayer.probe(for: key, keyNames: keyNames).map { (key, $0) }
            }
            let claimed = runtime.userClaimedKeys(probes.map(\.1), texts: texts)
            let claims = zip(probes, claimed).compactMap { probe, isClaimed in isClaimed ? probe.0 : nil }
            router.loadGhosttyKeybinds(binds, defaults: defaults, claims: claims, keyNames: keyNames)
        }
    }
}
