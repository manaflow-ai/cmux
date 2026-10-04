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

    /// User chords (`["ctrl+b", "c"]` in cmux.json); an action with one has
    /// no single-key shortcut.
    public internal(set) var chordOverrides: [ActionID: ShortcutChord] = [:] {
        didSet { shortcutIndex = nil }
    }

    /// App and keybindings.json entries, after the defaults and cmux.json (`KeyBindingLoader`).
    public internal(set) var keyBindingLayers = KeyBindingLayers() { didSet { shortcutIndex = nil } }

    /// User key-routing tiers (`cmux.json` `shortcuts.tiers`), see `ActionKeyTier`.
    public internal(set) var keyTierOverrides: [ActionID: ActionKeyTier] = [:]
    /// Features an administrator turned off (`DisabledFeatures`, ActionRegistry+Policy).
    public var disabledFeatures: Set<ActionFeature> = [] { didSet { shortcutIndex = nil } }

    /// Whether a menu item's key equivalent may run `id` now. The App
    /// installs its `KeyRouter` here so menus follow the same tier rules as
    /// the window (browser focus mode, text fields). Nil allows everything.
    @ObservationIgnored public var menuKeyEquivalentGate: (@MainActor (ActionID) -> Bool)?
    /// True while AppKit dispatches a key-down (a menu key equivalent), not
    /// a click in an open menu. Replaceable in tests.
    @ObservationIgnored public var isDispatchingKeyDown: @MainActor () -> Bool = { NSApp.currentEvent?.type == .keyDown }

    /// Collects missing required arguments (the palette installs itself
    /// here) and then calls `perform(_:invocation:)` again. When nil, the
    /// handler runs with what it has.
    @ObservationIgnored public var argumentCollector: (@MainActor (ActionID, ActionInvocation) -> Void)?
    /// Called while a choices submenu (`ContextMenuEntry.choices`) is open:
    /// with the hovered value (action, argument name, value, target), and
    /// with a nil value when the menu closes. The App previews themes here.
    @ObservationIgnored public var choicePreview: (@MainActor (ActionID, String, String?, ActionTargetRef?) -> Void)?
    /// Every known value of a suggested argument (`ActionSuggestions.source`),
    /// supplied by the App.
    @ObservationIgnored public var argumentSuggestions: (@MainActor (String) -> [ActionEnumCase])?
    /// Shortcut recorders open now (`ShortcutRecorder`); any open one sets `.recordingShortcut`.
    @ObservationIgnored var openShortcutRecorders: Set<ObjectIdentifier> = []
    /// Whether free text is a valid value of a suggested argument (a theme
    /// Ghostty accepts); nil accepts any non-empty text.
    @ObservationIgnored public var argumentValidation: (@MainActor (String, String) -> Bool)?
    /// The current value of a choices submenu's argument for a target, shown
    /// with a checkmark.
    @ObservationIgnored public var choiceState: (@MainActor (ActionID, ActionTargetRef?) -> String?)?

    /// Old IDs folded into canonical IDs on register and lookup.
    @ObservationIgnored public private(set) var aliases: [ActionID: ActionID] = [:]

    /// Sees every `refuse(_:)` reason (the App logs it and beeps).
    @ObservationIgnored public var refusalObserver: (@MainActor (String) -> Void)?

    /// Confirms destructive actions run from the keyboard, menu, or palette
    /// (`ActionRegistry+Confirmation`). Nil refuses them.
    @ObservationIgnored public var confirmationPresenter: ConfirmationPresenter?

    /// Wraps every handler run with its invocation. The App routes the run
    /// to the machine that owns the invocation's explicit target.
    @ObservationIgnored public var invocationScope: (@MainActor (ActionInvocation, () -> Void) -> Void)?
    /// The key window's claim on a run (``KeyWindowRoute``), asked first by `perform` and menu validation.
    @ObservationIgnored public var keyWindowRoute: (@MainActor (ActionID, ActionInvocation) -> KeyWindowRoute?)?
    @ObservationIgnored public internal(set) var isCapturingRefusal = false
    @ObservationIgnored var capturedRefusal: String?
    /// The captured refusal said an explicit target names nothing.
    @ObservationIgnored var capturedRefusalIsNotFound = false
    /// A caller shows refusals itself (the palette): no beep, but unlike
    /// capturing, destructive actions still ask for confirmation.
    @ObservationIgnored public internal(set) var isReportingRefusal = false
    @ObservationIgnored var reportedRefusal: String?
    @ObservationIgnored var capturedWork: [ActionWork]?
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
        bind(id, isEnabled: isEnabled, argumentHandler: argumentHandler, invoke: nil, handler: handler)
    }

    /// Binds a typed handler that receives the target and arguments.
    @discardableResult
    public func bind(
        _ id: ActionID,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        invoke: @escaping @MainActor (ActionInvocation) -> Void
    ) -> Bool {
        bind(id, isEnabled: isEnabled, argumentHandler: nil, invoke: invoke, handler: {})
    }

    private func bind(
        _ id: ActionID,
        isEnabled: @escaping @MainActor () -> Bool,
        argumentHandler: (@MainActor (String) -> Void)?,
        invoke: (@MainActor (ActionInvocation) -> Void)?,
        handler: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let descriptor = descriptor(for: id) else { return false }
        register(Action(
            id: descriptor.id,
            title: descriptor.title,
            keywords: descriptor.keywords,
            isEnabled: isEnabled,
            argumentHandler: argumentHandler,
            invoke: invoke,
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

    /// Whether the action applies in `context` (default: the current one): policy allows it, its
    /// required context is present, and it is not debug-only without developer tools (`DevTools`).
    public func isAvailable(_ id: ActionID, in context: ActionContext? = nil) -> Bool {
        guard let descriptor = descriptor(for: id) else { return isBound(id) }
        return ActionFeature.turnedOff(descriptor, in: disabledFeatures) == nil && Self.isAvailable(descriptor, in: context ?? self.context)
    }

    /// `isAvailable(_:in:)` with the facts the invocation's explicit target
    /// implies (`ActionContext.implied(by:)`).
    public func isAvailable(_ id: ActionID, for invocation: ActionInvocation) -> Bool {
        isAvailable(id, in: (invocation.keyContext ?? context).union(ActionContext.implied(by: invocation)))
    }

    public static func isAvailable(_ descriptor: ActionDescriptor, in context: ActionContext) -> Bool {
        if descriptor.isDebugOnly && !DevTools.isEnabled { return false }
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
        perform(id, invocation: ActionInvocation())
    }

    /// Performs an action that takes one argument. The text is parsed with
    /// the descriptor's first argument; handlers without a schema get it
    /// through `argumentHandler`.
    @discardableResult
    public func perform(_ id: ActionID, argument: String) -> Bool {
        let schema = descriptor(for: id)?.arguments.first
        let name = schema?.name ?? "value"
        let value = schema?.parse(argument) ?? .string(argument)
        return perform(id, invocation: ActionInvocation(arguments: [name: value]))
    }

    /// Performs with a target and typed arguments (palette, CLI, context menus). Fails when a required argument is missing.
    @discardableResult
    public func perform(_ id: ActionID, invocation: ActionInvocation) -> Bool {
        if disabledFeature(for: id) != nil { return false }
        if let route = keyWindowRoute?(canonicalID(for: id), invocation) { return route.perform { refuse($0) } }
        guard let action = action(for: id), isAvailable(id, for: invocation), action.isEnabled() else { return false }
        if ActionTargetReasons.refuses(action, invocation, in: self) { return false }
        let missing = descriptor(for: id).map { descriptor in
            descriptor.arguments.contains { $0.isRequired && invocation.arguments[$0.name] == nil && !Self.target(of: invocation, supplies: $0, for: descriptor) }
        } ?? false
        if missing, let argumentCollector {
            // A menu item or shortcut for an argument-taking action: let the
            // palette ask for the rest, then run with the full invocation.
            argumentCollector(id, invocation)
            return true
        }
        if needsConfirmation(id, invocation) { return gateDestructive(id, invocation) }
        runScoped(action, id, invocation)
        return true
    }

    /// IDs of catalog actions without a handler. The App's conformance test
    /// asserts this is empty.
    public func unboundActionIDs() -> [ActionID] {
        descriptors.map(\.id).filter { !isBound($0) }
    }

    func bestCandidate(_ ids: [ActionID]) -> ActionID? {
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
    /// Delegates of open choices submenus, released with their menu.
    @ObservationIgnored let choiceCoordinators = NSMapTable<NSMenu, ActionChoicesMenuCoordinator>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    /// A target of an argument's kind supplies that argument when the
    /// action does not act on that kind itself: right-clicking a browser
    /// profile and choosing New Tab with Browser Profile… uses that profile,
    /// while Merge Workspace into… (which acts on a workspace) still asks
    /// for the other workspace.
    static func target(of invocation: ActionInvocation, supplies argument: ActionArgument, for descriptor: ActionDescriptor) -> Bool {
        guard case .target(let kind) = argument.kind, let target = invocation.target else { return false }
        return target.kind == kind && !descriptor.targets.contains(kind)
    }

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
