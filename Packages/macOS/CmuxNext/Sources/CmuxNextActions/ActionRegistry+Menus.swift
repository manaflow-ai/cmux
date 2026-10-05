public import AppKit

extension ActionRegistry {
    // MARK: - Search and menus

    /// Bound actions ranked for a query. An empty query returns every bound
    /// action in registration order. The palette uses its own index; this is
    /// for simple callers such as the debug socket.
    public func search(_ query: String) -> [Action] {
        let parsed = FuzzyQuery(query)
        guard !parsed.isEmpty else { return actions }
        return actions
            .compactMap { action -> (Action, Int)? in
                var fields = [FuzzyField(FuzzyText(title(for: action.id) ?? action.title))]
                fields += action.keywords.map { FuzzyField(FuzzyText($0), weight: 80) }
                guard let score = FuzzyMatcher.score(parsed, fields: fields) else { return nil }
                return (action, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// A menu item that performs `id` and shows its effective shortcut. Nil
    /// when `id` is neither bound nor in the catalog.
    public func makeMenuItem(for id: ActionID) -> NSMenuItem? {
        let id = canonicalID(for: id)
        guard let title = title(for: id) else { return nil }
        let shortcut = effectiveShortcut(for: id)
        let isFamily = descriptor(for: id)?.shortcutFamily != nil
        let item = NSMenuItem(
            title: title,
            action: #selector(ActionMenuTarget.performAction(_:)),
            keyEquivalent: isFamily ? "" : (shortcut?.key ?? "")
        )
        item.keyEquivalentModifierMask = isFamily ? [] : (shortcut?.modifiers ?? [])
        item.representedObject = id.rawValue
        item.target = menuTarget
        return item
    }

    /// A menu item that runs `id` on `target`, titled `title` when given
    /// (a tab strip button's own label) and otherwise by the action.
    public func makeMenuItem(for id: ActionID, target: ActionTargetRef?, title: String? = nil) -> NSMenuItem? {
        guard let item = makeMenuItem(for: id) else { return nil }
        if let title { item.title = title }
        item.representedObject = ActionMenuPayload(id: canonicalID(for: id), target: target)
        return item
    }
}

extension ActionRegistry {
    /// The action, target and arguments a generated menu item runs (nil
    /// for items the registry did not make). Callers that retitle a row
    /// (Search Google for "…") and tests read it.
    public static func menuRun(of item: NSMenuItem) -> (id: ActionID, target: ActionTargetRef?, arguments: [String: ActionValue])? {
        guard let payload = item.representedObject as? ActionMenuPayload else { return nil }
        return (payload.id, payload.target, payload.arguments)
    }
}

/// What a menu item runs: an action and, for context menus, its target
/// (and, for a choices submenu, the chosen argument).
final class ActionMenuPayload: NSObject {
    let id: ActionID
    let target: ActionTargetRef?
    let arguments: [String: ActionValue]

    init(id: ActionID, target: ActionTargetRef?, arguments: [String: ActionValue] = [:]) {
        self.id = id
        self.target = target
        self.arguments = arguments
    }
}

/// Objective-C target that forwards menu selections to the registry.
final class ActionMenuTarget: NSObject, NSMenuItemValidation {
    private weak var registry: ActionRegistry?

    init(registry: ActionRegistry) {
        self.registry = registry
    }

    @objc func performAction(_ sender: NSMenuItem) {
        guard let registry, let payload = Self.payload(of: sender) else { return }
        registry.perform(payload.id, invocation: ActionInvocation(target: payload.target, arguments: payload.arguments))
    }

    /// A key equivalent also asks the registry's `menuKeyEquivalentGate`,
    /// so a chord the key router gave to a page or text field cannot fire
    /// the menu item afterwards. Clicks in an open menu are not gated.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let registry, let payload = Self.payload(of: menuItem) else { return false }
        // A feature an administrator turned off leaves the menu (DisabledFeatures).
        menuItem.isHidden = registry.disabledFeature(for: payload.id) != nil
        if menuItem.isHidden { return false }
        // A standalone key window claims the run: its close items stay
        // enabled (they close it), actions on main window content are off.
        let invocation = ActionInvocation(target: payload.target, arguments: payload.arguments)
        if let route = registry.keyWindowRoute?(registry.canonicalID(for: payload.id), invocation) { return route.enablesMenuItem }
        guard ActionTargetReasons.canPerform(payload.id, invocation: ActionInvocation(target: payload.target), in: registry) else { return false }
        if let gate = registry.menuKeyEquivalentGate, !menuItem.keyEquivalent.isEmpty, registry.isDispatchingKeyDown() {
            return gate(payload.id)
        }
        return true
    }

    private static func payload(of item: NSMenuItem) -> ActionMenuPayload? {
        if let payload = item.representedObject as? ActionMenuPayload { return payload }
        if let raw = item.representedObject as? String { return ActionMenuPayload(id: ActionID(rawValue: raw), target: nil) }
        return nil
    }
}
