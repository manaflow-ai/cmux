public import AppKit

extension ActionRegistry {
    /// A submenu item for a choices entry: one item per value of the
    /// action's first enumeration argument, each performing the action with
    /// that value and `target`. Nil when the action has no such argument or
    /// is not bound.
    /// `context` is the menu's effective context (the window's plus the
    /// menu's implied names), the same one every other row is shown by.
    func makeChoicesItem(for descriptor: ActionDescriptor, target: ActionTargetRef?, in context: ActionContext) -> NSMenuItem? {
        guard let title = title(for: descriptor.id), let action = action(for: descriptor.id),
              Self.isAvailable(descriptor, in: context), action.isEnabled(),
              let (argument, cases) = descriptor.arguments.lazy.compactMap(Self.menuChoices).first
        else { return nil }
        let current = choiceState?(descriptor.id, target)
        let submenu = NSMenu(title: title)
        let coordinator = ActionChoicesMenuCoordinator(registry: self, action: descriptor.id, argument: argument.name, target: target)
        // `NSMenu.delegate` is weak; the coordinator lives as long as the menu.
        choiceCoordinators.setObject(coordinator, forKey: submenu)
        submenu.delegate = coordinator
        for choice in cases {
            let item = NSMenuItem(title: choice.title, action: #selector(ActionMenuTarget.performAction(_:)), keyEquivalent: "")
            item.target = menuTarget
            item.representedObject = ActionMenuPayload(id: descriptor.id, target: target, arguments: [argument.name: .string(choice.value)])
            item.state = choice.value == current ? .on : .off
            submenu.addItem(item)
        }
        if argument.suggestions != nil {
            // The full list, with type-to-search, in the palette.
            submenu.addItem(.separator())
            let more = NSMenuItem(title: ActionSuggestionsStrings.more, action: #selector(ActionMenuTarget.performAction(_:)), keyEquivalent: "")
            more.target = menuTarget
            more.representedObject = ActionMenuPayload(id: descriptor.id, target: target)
            submenu.addItem(more)
        }
        let item = NSMenuItem(title: title.hasSuffix("…") ? String(title.dropLast()) : title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}

extension ActionRegistry {
    /// The menu items of an argument: every case of an enumeration, or the
    /// pinned values of a suggested string.
    nonisolated static func menuChoices(_ argument: ActionArgument) -> (ActionArgument, [ActionEnumCase])? {
        if case .enumeration(let cases) = argument.kind { return (argument, cases) }
        if let suggestions = argument.suggestions, !suggestions.pinned.isEmpty { return (argument, suggestions.pinned) }
        return nil
    }
}

nonisolated enum ActionSuggestionsStrings {
    static var more: String {
        String(localized: "argument.value.more", defaultValue: "More…", table: "ThemeActions", bundle: .module)
    }
}

/// Reports the hovered choice to `ActionRegistry.choicePreview` and a nil
/// value when the submenu closes. A chosen item runs its action; the App
/// keeps that value showing until it is saved, so the revert does not flash.
final class ActionChoicesMenuCoordinator: NSObject, NSMenuDelegate {
    private weak var registry: ActionRegistry?
    private let action: ActionID
    private let argument: String
    private let target: ActionTargetRef?

    init(registry: ActionRegistry, action: ActionID, argument: String, target: ActionTargetRef?) {
        self.registry = registry
        self.action = action
        self.argument = argument
        self.target = target
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let value = (item?.representedObject as? ActionMenuPayload)?.arguments[argument]?.stringValue
        registry?.choicePreview?(action, argument, value, target)
    }

    func menuDidClose(_ menu: NSMenu) {
        registry?.choicePreview?(action, argument, nil, target)
    }
}
