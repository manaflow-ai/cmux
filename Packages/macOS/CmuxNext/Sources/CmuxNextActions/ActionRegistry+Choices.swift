public import AppKit

extension ActionRegistry {
    /// A submenu item for a choices entry: one item per value of the
    /// action's first enumeration argument, each performing the action with
    /// that value and `target`. Nil when the action has no such argument or
    /// is not bound.
    func makeChoicesItem(for descriptor: ActionDescriptor, target: ActionTargetRef?) -> NSMenuItem? {
        guard let title = title(for: descriptor.id), canPerform(descriptor.id),
              let argument = descriptor.arguments.first(where: { if case .enumeration = $0.kind { true } else { false } }),
              case .enumeration(let cases) = argument.kind
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
        let item = NSMenuItem(title: title.hasSuffix("…") ? String(title.dropLast()) : title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
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
