/// The binding table view of a registry (plans/cmux-next/keybindings.md
/// section 4): the table every key-down resolves against, whether an action
/// can run in a window's context, and running a resolved binding there.
@MainActor
public struct RegistryKeyBindings {
    public let registry: ActionRegistry

    public init(_ registry: ActionRegistry) {
        self.registry = registry
    }

    /// The binding table, rebuilt when a binding changes (same lifetime as
    /// the registry's shortcut index).
    ///
    /// Layers (GHOSTTY-CONFIG keybind order): Ghostty fallbacks (every
    /// routed Ghostty keybind), defaults (the tab-switch entries of
    /// ``KeyBindingDefaults``, then the catalog's default keys), app
    /// entries, the keybinds the user's Ghostty config changed (terminal
    /// only), then user entries (cmux.json, then keybindings.json;
    /// ``KeyBindingLayers``). A later entry wins. Inside a layer, entries are ordered by the number
    /// of context facts their action requires, so a more specific default
    /// (Cmd-R Reload in a page) comes after a general one (Cmd-R Rename
    /// Tab), and catalog order breaks a tie (the first catalog action wins).
    public var table: KeyBindingTable {
        if let table = registry.currentShortcutIndex().bindingTable { return table }
        let table = makeTable()
        registry.shortcutIndex?.bindingTable = table
        return table
    }

    /// Bound, available in `context` (the key window's facts), and enabled.
    public func canPerform(_ id: ActionID, in context: ActionContext) -> Bool {
        guard let action = registry.action(for: id), registry.isAvailable(id, in: context) else { return false }
        return action.isEnabled()
    }

    /// Runs a resolved binding with the context of the window whose key
    /// ran it, so availability is checked against that window, never
    /// against the context another window published.
    @discardableResult
    public func run(_ binding: KeyBinding, keyContext: ActionContext) -> Bool {
        var invocation = ActionInvocation(arguments: binding.arguments)
        if let argument = binding.argument {
            let schema = registry.descriptor(for: binding.command)?.arguments.first
            invocation.arguments[schema?.name ?? "value"] = schema?.parse(argument) ?? .string(argument)
        }
        invocation.keyContext = keyContext
        return registry.perform(binding.command, invocation: invocation)
    }

    private func makeTable() -> KeyBindingTable {
        typealias Ranked = (binding: KeyBinding, specificity: Int, order: Int)
        var layers: [KeyBinding.Source: [Ranked]] = [:]
        var ids = registry.descriptors.map(\.id)
        ids += registry.actions.map(\.id).filter { registry.descriptorIndexByID[$0] == nil }
        for (order, id) in ids.enumerated() where registry.disabledFeature(for: id) == nil {
            let requires = registry.descriptor(for: id)?.requires ?? []
            let when = WhenClause.requiring(requires)
            // The code editor's editing chords win over these defaults (R127).
            let defaultWhen = KeyBindingDefaults.yieldsToCodeEditor.contains(id)
                ? WhenClause.and([when, .not(.has(KeyContext.codeEditorFocusedKey))].compactMap { $0 }) : when
            let specificity = requires.rawValue.nonzeroBitCount
            func add(_ keys: [Shortcut], argument: String?, source: KeyBinding.Source) {
                let binding = KeyBinding(keys: keys, command: id, argument: argument, when: source == .default ? defaultWhen : when, source: source)
                layers[source, default: []].append((binding, specificity, order))
            }
            let userChord = registry.chordOverrides[id] != nil
            if let chord = registry.effectiveChord(for: id) {
                for (second, argument) in expandFamily(id, chord.second) {
                    add([chord.first, second], argument: argument, source: userChord ? .user : .default)
                }
                if userChord { continue }
            }
            guard let shortcut = registry.effectiveShortcut(for: id) else { continue }
            for (key, argument) in expandFamily(id, shortcut) { add([key], argument: argument, source: source(id, shortcut)) }
        }
        let extra = registry.keyBindingLayers
        let enabled = { (entry: KeyBinding) in registry.disabledFeature(for: entry.command) == nil }
        let fallbacks = extra.ghostty.filter { $0.source == .ghosttyFallback && enabled($0) }
        var entries = KeyBindingDefaults.entries(registry: registry)
        let removals = extra.removals
        // A removal takes out default and app entries, never a Ghostty keybind.
        let isRemoved = { (entry: KeyBinding) in !entry.source.isGhostty && removals.contains { $0.removes(entry) } }
        var removed: [KeyBinding] = []
        for source in KeyBinding.Source.allCases {
            if source == .user, !removals.isEmpty {
                removed = entries.filter(isRemoved)
                entries.removeAll(where: isRemoved)
            }
            let ranked = (layers[source] ?? []).sorted { lhs, rhs in
                lhs.specificity != rhs.specificity ? lhs.specificity < rhs.specificity : lhs.order > rhs.order
            }
            entries += ranked.map(\.binding)
            switch source {
            case .ghosttyFallback, .default: break
            case .app: entries += extra.app.filter(enabled)
            case .ghostty: entries += extra.ghostty.filter { $0.source == .ghostty && enabled($0) }
            case .user: entries += extra.user.filter(enabled)
            }
        }
        return KeyBindingTable(fallbacks + entries, removed: removed)
    }

    /// A user override equal to the catalog default stays a default entry,
    /// so writing the default key into cmux.json changes nothing.
    private func source(_ id: ActionID, _ shortcut: Shortcut) -> KeyBinding.Source {
        guard let override = registry.shortcutOverrides[id], override != nil else { return .default }
        return override == registry.descriptor(for: id)?.defaultShortcut ? .default : .user
    }

    /// A numbered family's keys `1` to `9` with their digit, else the key.
    private func expandFamily(_ id: ActionID, _ shortcut: Shortcut) -> [(Shortcut, String?)] {
        guard registry.isDigitFamily(id, shortcut) else { return [(shortcut, nil)] }
        return (1...9).map { (Shortcut(String($0), modifiers: shortcut.modifiers), String($0)) }
    }
}
