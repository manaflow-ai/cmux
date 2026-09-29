public import AppKit
public import Observation

/// Single registry of every action in the app.
///
/// The command palette searches it, menus are built from it, the window's
/// key router asks it first, and the debug socket performs by ID. Register
/// each behavior once here instead of wiring each surface separately.
@Observable
public final class ActionRegistry {
    public private(set) var actions: [Action] = []

    @ObservationIgnored private var indexByID: [ActionID: Int] = [:]

    public init() {}

    /// Registers `action`, replacing any action with the same ID.
    public func register(_ action: Action) {
        if let index = indexByID[action.id] {
            actions[index] = action
        } else {
            indexByID[action.id] = actions.count
            actions.append(action)
        }
    }

    public func action(for id: ActionID) -> Action? {
        indexByID[id].map { actions[$0] }
    }

    /// Performs the action if it exists and is enabled. Returns whether it ran.
    @discardableResult
    public func perform(_ id: ActionID) -> Bool {
        guard let action = action(for: id), action.isEnabled() else { return false }
        action.handler()
        return true
    }

    /// Performs the first enabled action whose shortcut matches `event`.
    /// Called by the window before the event reaches the terminal.
    public func performShortcut(for event: NSEvent) -> Bool {
        guard let action = actions.first(where: { $0.shortcut?.matches(event) == true }),
              action.isEnabled()
        else { return false }
        action.handler()
        return true
    }

    /// Actions ranked for a palette query. An empty query returns every
    /// action in registration order.
    public func search(_ query: String) -> [Action] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return actions }
        return actions
            .compactMap { action -> (Action, Int)? in
                let haystacks = [action.title] + action.keywords
                guard let best = haystacks.compactMap({ FuzzyMatch.score(needle, in: $0) }).max() else {
                    return nil
                }
                return (action, best)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// A menu item that performs `id` and shows its shortcut. Nil when the
    /// action is not registered.
    public func makeMenuItem(for id: ActionID) -> NSMenuItem? {
        guard let action = action(for: id) else { return nil }
        let item = NSMenuItem(title: action.title, action: #selector(ActionMenuTarget.performAction(_:)), keyEquivalent: action.shortcut?.key ?? "")
        item.keyEquivalentModifierMask = action.shortcut?.modifiers ?? []
        item.representedObject = id.rawValue
        item.target = menuTarget
        return item
    }

    @ObservationIgnored private lazy var menuTarget = ActionMenuTarget(registry: self)
}

/// Objective-C target that forwards menu selections to the registry.
final class ActionMenuTarget: NSObject, NSMenuItemValidation {
    private weak var registry: ActionRegistry?

    init(registry: ActionRegistry) {
        self.registry = registry
    }

    @objc func performAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        registry?.perform(ActionID(rawValue: raw))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let raw = menuItem.representedObject as? String,
              let action = registry?.action(for: ActionID(rawValue: raw))
        else { return false }
        return action.isEnabled()
    }
}
