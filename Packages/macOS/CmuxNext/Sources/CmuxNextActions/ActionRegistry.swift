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
    /// The facts an explicit target brings to a run (`--target pane:…` of an agent
    /// chat's pane: agentPaneFocused), so a script's run of a focus-gated action
    /// does not depend on what the person focuses. Published by the App.
    @ObservationIgnored public var targetContext: (@MainActor (ActionInvocation) -> ActionContext)?

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

    /// More keys for an action than its override (`{"any": [...]}` in
    /// cmux.json): each one key or a two-key chord, all running it too. The
    /// override stays the key menus show; replacing it clears these.
    public internal(set) var alternateShortcuts: [ActionID: [[Shortcut]]] = [:] {
        didSet { shortcutIndex = nil }
    }

    /// App and keybindings.json entries, after the defaults and cmux.json (`KeyBindingLoader`).
    public internal(set) var keyBindingLayers = KeyBindingLayers() { didSet { shortcutIndex = nil } }

    /// User key-routing tiers (`cmux.json` `shortcuts.tiers`), see `ActionKeyTier`.
    public internal(set) var keyTierOverrides: [ActionID: ActionKeyTier] = [:]
    /// Features an administrator turned off (`DisabledFeatures`, ActionRegistry+Policy).
    public var disabledFeatures: Set<ActionFeature> = [] { didSet { shortcutIndex = nil } }
    /// Why a cmux.json setting turns `id` off now (`browser.import.enabled`), or nil. Such an action
    /// leaves the palette, menus and context menus, and a run is refused with this reason (the
    /// person's own choice, not `DisabledFeatures`). The App installs it.
    @ObservationIgnored public var settingOffReason: @MainActor (ActionID) -> String? = { _ in nil }
    /// The person's arrangement of each right-click menu (cmux.json `contextMenus.layouts`,
    /// ``ContextMenuLayout``); a menu without one is drawn as generated.
    public var contextMenuLayouts: [ActionMenuContext: ContextMenuLayout] = [:]
    /// Whether a whole right-click menu ends with Customize Menu… (cmux.json `contextMenus.showCustomizeItem`).
    public var showsCustomizeMenuItem = true
    /// Customize Menu…: opens Settings > Menus on that menu. The App installs it; nil shows no row.
    @ObservationIgnored public var customizeMenu: (@MainActor (ActionMenuContext) -> Void)?

    /// Whether a menu item's key equivalent may run `id` now. The App
    /// installs its `KeyRouter` here so menus follow the same tier rules as
    /// the window (browser focus mode, text fields). Nil allows everything.
    @ObservationIgnored public var menuKeyEquivalentGate: (@MainActor (ActionID) -> Bool)?
    /// Whether the binding table holds the workspaces-as-tabs keys (`KeyBindingDefaults.workspacesAsTabs`).
    /// The App reads its Debug tunable here; off (the default), the table, the shortcut list and its
    /// conflicts are the shipped ones.
    @ObservationIgnored public var includesWorkspaceTabKeys: @MainActor () -> Bool = { false }
    /// True while AppKit dispatches a key-down (a menu key equivalent), not
    /// a click in an open menu. The App installs it from its input dispatch context (`InputDispatchContext`), as
    /// ``dispatchingInputEvent``: `NSApp.currentEvent` keeps the last key after its dispatch, so a
    /// socket or CLI run after a key press would pass for one. False (the default) outside the App;
    /// replaceable in tests.
    @ObservationIgnored public var isDispatchingKeyDown: @MainActor () -> Bool = { false }
    /// The OS input event AppKit is dispatching now (inside `NSApplication.sendEvent`), nil
    /// between dispatches. The App installs it (`InputDispatchContext`: `sendEvent`'s event and the key router's own); the action
    /// signposts read it for a `user` run's `input_age_ms`. Nil (the default) records -1.
    @ObservationIgnored public var dispatchingInputEvent: @MainActor () -> NSEvent? = { nil }
    /// Times each run that does work (``ActionRunTiming``; `action.perform` / `action.commit`), and
    /// each gate (`action.gate`).
    let runTiming: any ActionRunTiming
    /// The end of the gate interval open now (`ActionRegistry+Signposts`), ended before anything
    /// else is timed so a gate never encloses the run it lets through.
    @ObservationIgnored var openGateEnd: (@MainActor () -> Void)?

    /// Collects missing required arguments (the palette installs itself
    /// here) and then calls `perform(_:invocation:)` again. When nil, the
    /// handler runs with what it has.
    @ObservationIgnored public var argumentCollector: (@MainActor (ActionID, ActionInvocation) -> Void)?
    /// Asks for one argument inline, also an optional one (the palette installs itself here), then
    /// calls `perform(_:invocation:)` again with it (`ask(_:_:_:)`).
    @ObservationIgnored public var argumentAsker: (@MainActor (ActionID, ActionInvocation, ActionArgumentAsk) -> Void)?
    /// Called while a choices submenu (`ContextMenuEntry.choices`) is open:
    /// with the hovered value (action, argument name, value, target), and
    /// with a nil value when the menu closes. The App previews themes here.
    @ObservationIgnored public var choicePreview: (@MainActor (ActionID, String, String?, ActionTargetRef?, _ machineID: String?) -> Void)?
    /// Live previews by action (`ActionRegistry+Preview`) and the one on screen.
    @ObservationIgnored var previews: [ActionID: ActionPreview] = [:]
    @ObservationIgnored var activePreview: ActivePreview?
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
    @ObservationIgnored public var targetChoices: (@MainActor (_ action: ActionID, _ kind: ActionTargetKind, _ target: ActionTargetRef?) -> ActionTargetChoices?)?

    /// Old IDs folded into canonical IDs on register and lookup.
    @ObservationIgnored public private(set) var aliases: [ActionID: ActionID] = [:]

    /// Ways past an unavailable reason that a person's own gesture may take (``ActionRecovery``),
    /// asked in order with the action and its current reason; the first non-nil answer wins.
    @ObservationIgnored public var unavailableRecoveries: [@MainActor (_ action: ActionID, _ reason: String) -> ActionRecovery?] = []
    /// Sees every `refuse(_:quiet:)` reason and whether it is quiet (the App logs it; a loud one shows the HUD).
    @ObservationIgnored public var refusalObserver: (@MainActor (_ reason: String, _ quiet: Bool) -> Void)?
    /// Sees the remote half of an ``ActionEffect`` fail after its local change was rolled back, with
    /// the localized notice, for a run no caller waits on (a keyboard, menu or palette run): the App
    /// shows it where it shows refusals. A capturing caller (the control socket) reports it itself.
    @ObservationIgnored public var remoteFailureObserver: (@MainActor (_ action: ActionID, _ notice: String) -> Void)?
    /// Runs of ``ActionEffect/waiting(_:_:)`` effects since launch, by action and reason: the
    /// actions that still show nothing until a reply (`debug.action_budget`, the latency report).
    @ObservationIgnored public internal(set) var waitingRuns: [ActionID: [ActionWait: Int]] = [:]

    /// Confirms destructive actions run from the keyboard, menu, or palette
    /// (`ActionRegistry+Confirmation`). Nil refuses them.
    @ObservationIgnored public var confirmationPresenter: ConfirmationPresenter?

    /// Wraps every handler run with its invocation. The App routes the run
    /// to the machine that owns the invocation's explicit target.
    @ObservationIgnored public var invocationScope: (@MainActor (ActionInvocation, () -> Void) -> Void)?
    /// Each sees every handler run just before it runs, with the run's effective origin (a run
    /// nested in a CLI run is the CLI's): the sidebar animates only changes its user asked for.
    @ObservationIgnored public var willRunObservers: [@MainActor (ActionID, ActionOrigin) -> Void] = []
    /// Sees every handler run after it ran (the tips card's local usage flags).
    @ObservationIgnored public var runObserver: (@MainActor (ActionID, ActionInvocation) -> Void)?
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
    /// The value-producing tasks among ``capturedWork`` (`track(result:)`).
    @ObservationIgnored var capturedResults: [ActionResultWork]?
    @ObservationIgnored private var indexByID: [ActionID: Int] = [:]
    @ObservationIgnored var descriptorIndexByID: [ActionID: Int] = [:]
    @ObservationIgnored var shortcutIndex: ShortcutIndex?

    /// An empty registry with no catalog whose runs are not timed.
    public convenience init() {
        self.init(catalog: [])
    }

    /// A registry seeded with `catalog` whose runs are not timed (``NoActionRunTiming``): a
    /// test's registry writes no signposts and adds no run-loop observer.
    ///
    /// A separate symbol, not a default argument of ``init(catalog:aliases:runTiming:)``: objects
    /// compiled before the timing was injected call this one (warm fleet build trees link them).
    ///
    /// - Parameters:
    ///   - catalog: The descriptors.
    ///   - aliases: Old ids folded into canonical ids.
    public convenience init(catalog: [ActionDescriptor], aliases: [ActionID: ActionID] = [:]) {
        self.init(catalog: catalog, aliases: aliases, runTiming: NoActionRunTiming())
    }

    /// A registry seeded with `catalog` whose runs `runTiming` times.
    ///
    /// - Parameters:
    ///   - catalog: The descriptors (``ActionCatalog/all`` in the App).
    ///   - aliases: Old ids folded into canonical ids.
    ///   - runTiming: Times every run that does work. The App passes ``SignpostActionRunTiming``
    ///     at its composition root; tests pass a recorder.
    public init(catalog: [ActionDescriptor], aliases: [ActionID: ActionID] = [:],
                runTiming: any ActionRunTiming) {
        self.aliases = aliases
        self.runTiming = runTiming
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

    /// Ids bound twice without an `unbind` (two owners; the newer silently wins). Checked by the
    /// `noActionIsBoundTwice` test, never trapped; the app logs a fault. A real bind replacing a
    /// ``bindUnavailable(_:reason:)`` placeholder is no duplicate; anything else bound twice is.
    public private(set) var duplicateBindings: [ActionID] = []
    private var placeholders: Set<ActionID> = []

    func noteBinding(_ id: ActionID, placeholder: Bool) {
        let canonical = canonicalID(for: id)
        if indexByID[canonical] != nil, !placeholders.contains(canonical) { duplicateBindings.append(id) }
        if placeholder { placeholders.insert(canonical) } else { placeholders.remove(canonical) }
    }

    /// Registers `action`, replacing any action with the same ID. Legacy IDs
    /// are folded into their canonical ID.
    public func register(_ action: Action) {
        let id = canonicalID(for: action.id)
        var stored = id == action.id ? action : action.withID(id)
        // Interned here, when bound, so a run's timing looks nothing up (ActionBudgetMonitor).
        stored.timingIndex = runTiming.intern(id)
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
        noteBinding(descriptor.id, placeholder: false)
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
        placeholders.remove(id)
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
        return ActionFeature.turnedOff(descriptor, in: disabledFeatures) == nil && settingOffReason(descriptor.id) == nil
            && Self.isAvailable(descriptor, in: context ?? self.context)
    }

    /// `isAvailable(_:in:)` with the facts the invocation's explicit target
    /// implies (`ActionContext.implied(by:)`).
    public func isAvailable(_ id: ActionID, for invocation: ActionInvocation) -> Bool {
        let base = (invocation.keyContext ?? context).union(ActionContext.implied(by: invocation))
        // Asked only when the target is explicit and the run lacks a required fact.
        guard invocation.target != nil, let required = descriptor(for: id)?.requires, !base.isSuperset(of: required),
              let facts = targetContext?(invocation) else { return isAvailable(id, in: base) }
        return isAvailable(id, in: base.union(facts))
    }

    /// `isAvailable(_:for:)` for a run from outside the app (the CLI, MCP): a `pane:` or `tab:`
    /// target decides the facts it brings (`ActionContext.decidedByPaneOrTabTarget`) itself, so
    /// another agent chat or canvas that has the keyboard never stands in for the target's. A
    /// script's Set Agent Chat Model on a terminal pane is refused here, before anything runs,
    /// whatever the person focuses. The App's own runs on a chat's tab (its header, from a chat
    /// that may sit in no pane) keep `isAvailable(_:for:)`.
    public func isAvailable(_ id: ActionID, forScript invocation: ActionInvocation) -> Bool {
        guard let kind = invocation.target?.kind, kind == .pane || kind == .tab,
              let required = descriptor(for: id)?.requires, !required.isDisjoint(with: .decidedByPaneOrTabTarget),
              let targetContext else { return isAvailable(id, for: invocation) }
        let base = (invocation.keyContext ?? context).union(ActionContext.implied(by: invocation))
            .subtracting(.decidedByPaneOrTabTarget)
        return isAvailable(id, in: base.union(targetContext(invocation).intersection(.decidedByPaneOrTabTarget)))
    }

    public static func isAvailable(_ descriptor: ActionDescriptor, in context: ActionContext) -> Bool {
        if descriptor.isDebugOnly && !DevTools.isEnabled { return false }
        return context.isSuperset(of: descriptor.requires)
    }

    /// Bound, available in `context` (default: the current one), and its `isEnabled` predicate passes.
    public func canPerform(_ id: ActionID, in context: ActionContext? = nil) -> Bool {
        guard let action = action(for: id), isAvailable(id, in: context) else { return false }
        return action.isEnabled()
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
            if specificity > best?.specificity ?? Int.min {
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
    /// while Merge Workspace Into… (which acts on a workspace) still asks
    /// for the other workspace, unless the argument names the target itself
    /// (`isSuppliedByTarget`: New Workspace in Space… on a right-clicked Space).
    static func target(of invocation: ActionInvocation, supplies argument: ActionArgument, for descriptor: ActionDescriptor) -> Bool {
        guard case .target(let kind) = argument.kind, let target = invocation.target else { return false }
        return target.kind == kind && (argument.isSuppliedByTarget || !descriptor.targets.contains(kind))
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
