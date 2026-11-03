public import AppKit

extension ActionRegistry {
    // MARK: - Menus

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
        // Accessibility clients (computer-use agents) find a menu bar action by id in any language.
        item.identifier = NSUserInterfaceItemIdentifier("cmux.action.\(id.rawValue)")
        return item
    }
}

extension ActionRegistry {
    /// Binds one menu action to the machine that supplied its native target. Other items keep
    /// their ordinary invocation; no synthetic argument leaks into their handlers.
    public func scopeMenuAction(_ menu: NSMenu, action: ActionID, toMachine machineID: String) {
        for item in menu.items {
            if let payload = item.representedObject as? ActionMenuPayload, payload.id == action {
                payload.targetMachineID = machineID
                if let title = self.action(for: action)?.targetTitle?(payload.invocation(in: self)) { item.title = title }
            }
            if let submenu = item.submenu { scopeMenuAction(submenu, action: action, toMachine: machineID) }
        }
    }

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
    var targetMachineID: String?
    let arguments: [String: ActionValue]
    /// Focus facts the right-clicked object stands in for (`ActionRegistry.impliedContext(for:)`):
    /// the item is enabled and runs with them added to the window's context, the same facts
    /// that showed it (a Files row's menu runs the explorer's actions while a terminal has the keyboard).
    let implied: ActionContext

    init(id: ActionID, target: ActionTargetRef?, arguments: [String: ActionValue] = [:], implied: ActionContext = []) {
        self.id = id
        self.target = target
        self.arguments = arguments
        self.implied = implied
    }

    /// The run of this item in `registry`'s context, plus the implied facts.
    func invocation(in registry: ActionRegistry, withArguments: Bool = true) -> ActionInvocation {
        var invocation = ActionInvocation(target: target, arguments: withArguments ? arguments : [:])
        invocation.targetMachineID = targetMachineID
        if !implied.isEmpty { invocation.keyContext = registry.context.union(implied) }
        return invocation
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
        registry.perform(payload.id, invocation: payload.invocation(in: registry))
    }

    /// A key equivalent also asks the registry's `menuKeyEquivalentGate`,
    /// so a chord the key router gave to a page or text field cannot fire
    /// the menu item afterwards. Clicks in an open menu are not gated.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let registry, let payload = Self.payload(of: menuItem) else { return false }
        // A feature an administrator turned off leaves the menu (DisabledFeatures), and so does an
        // action a setting turns off (`browser.import.enabled`).
        menuItem.isHidden = registry.disabledFeature(for: payload.id) != nil || registry.settingOffReason(registry.canonicalID(for: payload.id)) != nil
        if menuItem.isHidden { return false }
        // A standalone key window claims the run: its close items stay
        // enabled (they close it), actions on main window content are off.
        var invocation = ActionInvocation(target: payload.target, arguments: payload.arguments)
        // A row scoped to its target's machine (``scopeMenuAction``) validates against that machine, as it runs.
        invocation.targetMachineID = payload.targetMachineID
        // A main menu toggle reads as the change it makes for the focused target (Pin
        // Workspace or Unpin Workspace, PINNED-ITEMS-END-TO-END); no target title, the
        // catalog's. Context menu items (an ActionMenuPayload) are decorated when built.
        if menuItem.representedObject is String, let targetTitle = registry.action(for: payload.id)?.targetTitle,
           let title = targetTitle(invocation) ?? registry.title(for: payload.id), menuItem.title != title {
            menuItem.title = title
        }
        if let route = registry.keyWindowRoute?(registry.canonicalID(for: payload.id), invocation) { return route.enablesMenuItem }
        let run = payload.invocation(in: registry, withArguments: false)
        // A row a recovery covers stays clickable: the click signs in, then runs it (``ActionRecovery``).
        guard ActionTargetReasons.canPerform(payload.id, invocation: run, in: registry)
            || registry.personRecovery(for: payload.id, run) != nil else { return false }
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
