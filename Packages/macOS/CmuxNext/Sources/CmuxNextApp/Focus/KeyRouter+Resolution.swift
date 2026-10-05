import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTerminal

// Resolution (plans/cmux-next/keybindings.md section 4): a key-down to its
// binding table winner, before the tier check. The table holds the Ghostty
// keybinds too (GHOSTTY-CONFIG order: cmux.json > the user's Ghostty keybinds
// in a terminal > cmux defaults > Ghostty keybinds as a fallback).
extension KeyRouter {
    /// A shortcut a key-down resolves to, before the tier check.
    nonisolated struct Candidate: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            /// A binding table entry (catalog default or cmux.json).
            case registry(argument: String?)
            /// A Ghostty keybind routed to a registry action (a `.ghostty` or
            /// `.ghosttyFallback` table entry).
            case ghostty(arguments: [String: ActionValue])
        }

        var id: ActionID
        var tier: ActionKeyTier
        var source: Source
        /// A binding's typed arguments.
        var arguments: [String: ActionValue] = [:]
    }

    /// The winning binding for a key-down in `context`: its characters, then
    /// its unshifted key ("}" or "]" for Shift-]).
    func resolve(_ event: NSEvent, context: KeyContext) -> KeyBinding? {
        let table = RegistryKeyBindings(registry).table
        let bits = context.bits
        for shortcut in ActionRegistry.shortcuts(for: event) {
            if let winner = table.resolve([shortcut], in: context, isRunnable: { [registry] in RegistryKeyBindings(registry).canPerform($0, in: bits) }).winner {
                return winner
            }
        }
        return nil
    }

    /// The candidate for a key-down in a window with `focus` (no chord).
    func candidate(for event: NSEvent, focus: FocusState, facts: Facts = Facts()) -> Candidate? {
        candidate(for: event, context: keyContext(for: focus, facts: facts), focus: focus)
    }

    func candidate(for event: NSEvent, context: KeyContext, focus: FocusState) -> Candidate? {
        guard let winner = resolve(event, context: context) else { return nil }
        let tier = registry.keyTier(for: winner.command)
        guard winner.source.isGhostty else {
            return Candidate(id: winner.command, tier: tier, source: .registry(argument: winner.argument), arguments: winner.arguments)
        }
        let isBrowser = BrowserChordTable.isBrowserContext(focus.resolved)
        // Page Back/Forward chords never run a Ghostty keybind.
        if !isBrowser, BrowserChordTable.isBrowserOnlyChord(event, registry: registry) { return nil }
        // Nor does a browser chord while a page, the address bar or the find
        // bar has the keyboard (Cmd-[ is Back there, not Ghostty's
        // `goto_split:previous`); see BrowserChordTable.
        if isBrowser, BrowserChordTable.isChromeChord(event) { return nil }
        return Candidate(id: winner.command, tier: tier, source: .ghostty(arguments: winner.arguments))
    }

    /// The Ghostty keybind a key-down has in the table (the shortcut
    /// recorder's note), whatever the focus: the routed action.
    func ghosttyBinding(for event: NSEvent) -> ActionID? {
        let entries = RegistryKeyBindings(registry).table.entries
        for shortcut in ActionRegistry.shortcuts(for: event) {
            if let entry = entries.last(where: { $0.source.isGhostty && $0.keys == [shortcut] }) { return entry.command }
        }
        return nil
    }

    /// A browser-only chord (page Back/Forward) outside a browser context
    /// does nothing and reaches no view (browser focus mode is a browser
    /// context, so it never gets here).
    func consumesBrowserOnlyChord(_ event: NSEvent, focus: FocusState) -> Bool {
        !BrowserChordTable.isBrowserContext(focus.resolved) && BrowserChordTable.isBrowserOnlyChord(event, registry: registry)
    }

    /// Whether the app-wide dispatcher runs `candidate` now: tiers 0 and 1
    /// for a cmux window or a Chromium page window over it (kept for the
    /// tier tables in tests; ``decide(_:focus:keyWindow:facts:)`` is the
    /// whole rule).
    nonisolated static func intercepts(_ candidate: Candidate, focus: FocusState, keyWindow: KeyWindowKind) -> Bool {
        guard keyWindow == .content, candidate.tier != .content else { return false }
        if case .ghostty = candidate.source, case .terminal = focus.resolved { return false }
        return allows(candidate.tier, focus: focus)
    }
}
