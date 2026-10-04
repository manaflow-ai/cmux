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
    /// Layers: defaults (the tab-switch entries of ``KeyBindingDefaults``,
    /// then the catalog's default keys), then app entries, then user
    /// entries (cmux.json, then keybindings.json; ``KeyBindingLayers``). A
    /// later entry wins. Inside a layer, entries are ordered by the number
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
            let specificity = requires.rawValue.nonzeroBitCount
            func add(_ keys: [Shortcut], argument: String?, source: KeyBinding.Source) {
                let binding = KeyBinding(keys: keys, command: id, argument: argument, when: when, source: source)
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
        var entries = KeyBindingDefaults.entries(registry: registry)
        for source in KeyBinding.Source.allCases {
            let ranked = (layers[source] ?? []).sorted { lhs, rhs in
                lhs.specificity != rhs.specificity ? lhs.specificity < rhs.specificity : lhs.order > rhs.order
            }
            entries += ranked.map(\.binding)
            switch source {
            case .default: break
            case .app: entries += registry.keyBindingLayers.app.filter { registry.disabledFeature(for: $0.command) == nil }
            case .user: entries += registry.keyBindingLayers.user.filter { registry.disabledFeature(for: $0.command) == nil }
            }
        }
        return KeyBindingTable(entries)
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
