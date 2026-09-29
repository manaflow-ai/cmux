public import AppKit
public import Observation

/// A catalog descriptor joined with its bound handler, if any. The palette
/// and shortcut settings list entries; unbound entries have no handler yet.
public struct ActionEntry: Identifiable {
    public let descriptor: ActionDescriptor
    public let action: Action?

    public var id: ActionID { descriptor.id }
    public var isBound: Bool { action != nil }
}

/// Single registry of every action in the app.
///
/// The command palette searches it, menus are built from it, the window's
/// key router asks it first, and the debug socket performs by ID. Register
/// each behavior once here instead of wiring each surface separately.
///
/// Two layers: `descriptors` (the declarative catalog, see `ActionCatalog`)
/// and `actions` (handlers the App binds by ID). Shortcuts resolve as user
/// override, then the bound action's shortcut, then the descriptor default,
/// so menus, the key router, the palette, and settings show one value.
@Observable
public final class ActionRegistry {
    /// Actions with bound handlers, in registration order.
    public private(set) var actions: [Action] = []

    /// Catalog descriptors, in catalog order.
    public private(set) var descriptors: [ActionDescriptor] = []

    /// Focus and session facts published by the App. Drives availability and
    /// which of several actions sharing a default shortcut runs.
    public var context: ActionContext = []

    /// User shortcut overrides (from `cmux.json` `shortcuts`). A stored nil
    /// removes the default shortcut.
    public internal(set) var shortcutOverrides: [ActionID: Shortcut?] = [:] {
        didSet { shortcutIndex = nil }
    }

    /// Old IDs folded into canonical IDs on register and lookup.
    @ObservationIgnored public private(set) var aliases: [ActionID: ActionID] = [:]

    @ObservationIgnored private var indexByID: [ActionID: Int] = [:]
    @ObservationIgnored var descriptorIndexByID: [ActionID: Int] = [:]
    @ObservationIgnored var shortcutIndex: ShortcutIndex?

    /// An empty registry with no catalog.
    public init() {}

    /// A registry seeded with `catalog`.
    public init(catalog: [ActionDescriptor], aliases: [ActionID: ActionID] = [:]) {
        self.aliases = aliases
        seed(catalog)
    }

    /// A registry seeded with the full cmux catalog and legacy aliases.
    public static func standard() -> ActionRegistry {
        ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
    }

    // MARK: - Catalog

    /// Adds or replaces descriptors by ID.
    public func seed(_ newDescriptors: [ActionDescriptor]) {
        for descriptor in newDescriptors {
            if let index = descriptorIndexByID[descriptor.id] {
                descriptors[index] = descriptor
            } else {
                descriptorIndexByID[descriptor.id] = descriptors.count
                descriptors.append(descriptor)
            }
        }
        shortcutIndex = nil
    }

    /// Maps legacy IDs to their canonical ID.
    public func addAliases(_ newAliases: [ActionID: ActionID]) {
        aliases.merge(newAliases) { _, new in new }
    }

    public func canonicalID(for id: ActionID) -> ActionID {
        aliases[id] ?? id
    }

    public func descriptor(for id: ActionID) -> ActionDescriptor? {
        descriptorIndexByID[canonicalID(for: id)].map { descriptors[$0] }
    }

    /// Every descriptor joined with its handler, plus bound actions that have
    /// no descriptor (as `.other`), in catalog then registration order.
    public var entries: [ActionEntry] {
        var result = descriptors.map { ActionEntry(descriptor: $0, action: action(for: $0.id)) }
        for action in actions where descriptorIndexByID[action.id] == nil {
            result.append(ActionEntry(descriptor: Self.synthesizedDescriptor(for: action), action: action))
        }
        return result
    }

    /// Title shown in every surface: the catalog title, else the bound title.
    public func title(for id: ActionID) -> String? {
        descriptor(for: id)?.title ?? action(for: id)?.title
    }

    // MARK: - Binding

    /// Registers `action`, replacing any action with the same ID. Legacy IDs
    /// are folded into their canonical ID.
    public func register(_ action: Action) {
        let id = canonicalID(for: action.id)
        let stored = id == action.id ? action : action.withID(id)
        if let index = indexByID[id] {
            actions[index] = stored
        } else {
            indexByID[id] = actions.count
            actions.append(stored)
        }
        shortcutIndex = nil
    }

    /// Binds a handler to a catalog descriptor, taking title, keywords, and
    /// shortcut from the descriptor. Returns false when `id` is not in the
    /// catalog (register an `Action` for ad hoc actions).
    @discardableResult
    public func bind(
        _ id: ActionID,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        argumentHandler: (@MainActor (String) -> Void)? = nil,
        handler: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let descriptor = descriptor(for: id) else { return false }
        register(Action(
            id: descriptor.id,
            title: descriptor.title,
            keywords: descriptor.keywords,
            isEnabled: isEnabled,
            argumentHandler: argumentHandler,
            handler: handler
        ))
        return true
    }

    /// Removes the handler for `id`. The descriptor stays in the catalog.
    public func unbind(_ id: ActionID) {
        let id = canonicalID(for: id)
        guard let index = indexByID[id] else { return }
        actions.remove(at: index)
        indexByID = Dictionary(uniqueKeysWithValues: actions.enumerated().map { ($1.id, $0) })
        shortcutIndex = nil
    }

    public func action(for id: ActionID) -> Action? {
        indexByID[canonicalID(for: id)].map { actions[$0] }
    }

    public func isBound(_ id: ActionID) -> Bool {
        indexByID[canonicalID(for: id)] != nil
    }

    // MARK: - Availability

    /// Whether the action applies in `context` (defaults to the current
    /// context): its required context is present and it is not debug-only
    /// in a release build. Independent of binding and `isEnabled`.
    public func isAvailable(_ id: ActionID, in context: ActionContext? = nil) -> Bool {
        guard let descriptor = descriptor(for: id) else { return isBound(id) }
        return Self.isAvailable(descriptor, in: context ?? self.context)
    }

    public static func isAvailable(_ descriptor: ActionDescriptor, in context: ActionContext) -> Bool {
        #if !DEBUG
        if descriptor.isDebugOnly { return false }
        #endif
        return context.isSuperset(of: descriptor.requires)
    }

    /// Bound, available, and its `isEnabled` predicate passes.
    public func canPerform(_ id: ActionID) -> Bool {
        guard let action = action(for: id), isAvailable(id) else { return false }
        return action.isEnabled()
    }

    // MARK: - Performing

    /// Performs the action if it is bound, available, and enabled. Returns
    /// whether it ran.
    @discardableResult
    public func perform(_ id: ActionID) -> Bool {
        guard let action = action(for: id), isAvailable(id), action.isEnabled() else { return false }
        action.handler()
        return true
    }

    /// Performs an argument-taking action with `argument`. Falls back to the
    /// plain handler when the action takes no argument.
    @discardableResult
    public func perform(_ id: ActionID, argument: String) -> Bool {
        guard let action = action(for: id), isAvailable(id), action.isEnabled() else { return false }
        if let argumentHandler = action.argumentHandler {
            argumentHandler(argument)
        } else {
            action.handler()
        }
        return true
    }

    /// Performs the best action for a key-down event. Called by the window
    /// before the event reaches the terminal.
    public func performShortcut(for event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        var keys: [String] = []
        if let key = event.charactersIgnoringModifiers?.lowercased() { keys.append(key) }
        // With shift held, charactersIgnoringModifiers can return the shifted
        // character ("}" for Shift-]); also try the unmodified key.
        if let base = event.characters(byApplyingModifiers: [])?.lowercased(), !keys.contains(base) {
            keys.append(base)
        }
        for key in keys {
            if let resolved = resolve(Shortcut(key, modifiers: flags)) {
                return run(resolved)
            }
        }
        return false
    }

    /// Runs whatever `shortcut` resolves to. Returns whether an action ran.
    @discardableResult
    public func performShortcut(_ shortcut: Shortcut) -> Bool {
        guard let resolved = resolve(shortcut) else { return false }
        return run(resolved)
    }

    /// The action `shortcut` triggers in the current context, plus the digit
    /// for numbered families. Among several candidates the one with the most
    /// specific required context wins, then catalog order.
    public func resolve(_ shortcut: Shortcut) -> (id: ActionID, argument: String?)? {
        let index = currentShortcutIndex()
        if let id = bestCandidate(index.byShortcut[shortcut] ?? []) {
            return (id, nil)
        }
        if shortcut.key.count == 1, let digit = shortcut.key.first, ("1"..."9").contains(digit) {
            let familyKey = Shortcut("1", modifiers: shortcut.modifiers)
            if let id = bestCandidate(index.digitFamilies[familyKey] ?? []) {
                return (id, String(digit))
            }
        }
        return nil
    }

    private func run(_ resolved: (id: ActionID, argument: String?)) -> Bool {
        if let argument = resolved.argument {
            return perform(resolved.id, argument: argument)
        }
        return perform(resolved.id)
    }

    private func bestCandidate(_ ids: [ActionID]) -> ActionID? {
        var best: (id: ActionID, specificity: Int)?
        for id in ids where canPerform(id) {
            let specificity = descriptor(for: id)?.requires.rawValue.nonzeroBitCount ?? 0
            if best == nil || specificity > best!.specificity {
                best = (id, specificity)
            }
        }
        return best?.id
    }

    @ObservationIgnored lazy var menuTarget = ActionMenuTarget(registry: self)

    static func synthesizedDescriptor(for action: Action) -> ActionDescriptor {
        ActionDescriptor(
            id: action.id,
            title: action.title,
            keywords: action.keywords,
            defaultShortcut: action.shortcut,
            category: .other
        )
    }
}
