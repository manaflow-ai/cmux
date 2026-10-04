/// Why an app or keybindings.json entry was left out of the binding table.
/// The entry is named by its layer and its position in that layer's list,
/// so the editor and the notification can point at it (R59).
public nonisolated struct KeyBindingIssue: Hashable, Sendable {
    public enum Kind: Error, Hashable, Sendable {
        /// No action has this id (or alias).
        case unknownCommand(String)
        /// The action's schema has no argument with this name.
        case unknownArgument(String)
        /// The value does not fit the argument's kind, range or cases.
        case invalidArgument(String)
        /// More than ``KeyBindingTable/maxSequenceLength`` keys.
        case tooManyKeys
        case noKeys
        /// Only Command and Control chords reach the key dispatcher.
        case firstKeyNeedsCommandOrControl
    }

    public var source: KeyBinding.Source
    /// The position in its layer's entries, or in the removals.
    public var index: Int
    public var kind: Kind
    public var isRemoval: Bool

    public init(source: KeyBinding.Source, index: Int, kind: Kind, isRemoval: Bool = false) {
        self.source = source
        self.index = index
        self.kind = kind
        self.isRemoval = isRemoval
    }
}

extension ActionRegistry {
    /// Loads app and user entries and user removals: each entry is checked against its
    /// action's schema (``validated(_:)``); an entry that fails is left out
    /// and reported, the others load. A required argument may be missing:
    /// running the binding asks for it, as the palette does.
    @discardableResult
    public func setKeyBindingLayers(_ layers: KeyBindingLayers) -> [KeyBindingIssue] {
        var issues: [KeyBindingIssue] = []
        func load(_ entries: [KeyBinding], _ source: KeyBinding.Source) -> [KeyBinding] {
            entries.enumerated().compactMap { index, entry in
                switch validated(entry) {
                case .success(let binding): return binding
                case .failure(let kind):
                    issues.append(KeyBindingIssue(source: source, index: index, kind: kind))
                    return nil
                }
            }
        }
        let removals = layers.removals.enumerated().compactMap { index, removal -> KeyBindingRemoval? in
            let id = canonicalID(for: removal.command)
            guard descriptor(for: id) != nil || action(for: id) != nil else {
                issues.append(KeyBindingIssue(source: .user, index: index, kind: .unknownCommand(removal.command.rawValue), isRemoval: true))
                return nil
            }
            var canonical = removal
            canonical.command = id
            return canonical
        }
        keyBindingLayers = KeyBindingLayers(app: load(layers.app, .app), user: load(layers.user, .user), removals: removals)
        return issues
    }

    /// `entry` with its canonical command id and its arguments converted to
    /// the schema's kinds (text that fits a kind is parsed: `"yes"` for a
    /// bool, `"tab:t1"` for a tab), or why it cannot load.
    public func validated(_ entry: KeyBinding) -> Result<KeyBinding, KeyBindingIssue.Kind> {
        guard let first = entry.keys.first else { return .failure(.noKeys) }
        guard entry.keys.count <= KeyBindingTable.maxSequenceLength else { return .failure(.tooManyKeys) }
        guard !first.modifiers.isDisjoint(with: [.command, .control]) else { return .failure(.firstKeyNeedsCommandOrControl) }
        let id = canonicalID(for: entry.command)
        var binding = entry
        binding.command = id
        guard let descriptor = descriptor(for: id) else {
            // An action registered without a catalog row takes no arguments.
            return action(for: id) == nil || !entry.arguments.isEmpty ? .failure(.unknownCommand(entry.command.rawValue)) : .success(binding)
        }
        for (name, value) in entry.arguments {
            guard let argument = descriptor.arguments.first(where: { $0.name == name }) else { return .failure(.unknownArgument(name)) }
            guard let converted = argument.accept(value) else { return .failure(.invalidArgument(name)) }
            binding.arguments[name] = converted
        }
        return .success(binding)
    }
}

extension ActionArgument {
    /// `value` as this argument's kind, or nil when it does not fit.
    nonisolated func accept(_ value: ActionValue) -> ActionValue? {
        switch (kind, value) {
        case (.string, .string), (.bool, .bool):
            return value
        case (.int(let range), .int(let number)):
            return range?.contains(number) ?? true ? value : nil
        case (.target(let targetKind), .target(let ref)):
            return ref.kind == targetKind ? value : nil
        case (.string, _):
            return nil
        case (_, .string(let text)):
            return parse(text)
        default:
            return nil
        }
    }
}
