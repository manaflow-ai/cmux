public import AppKit

extension ActionRegistry {
    /// A right-click row a person configured (a workspace group's `contextMenu` in cmux.json): it
    /// runs `id` on `target`, titled `title` (else the action's own title), and says why it is
    /// disabled as generated rows do. Nil when `id` is neither bound nor in the catalog.
    ///
    /// - Parameters:
    ///   - id: The action the row runs.
    ///   - target: The object the menu is for.
    ///   - title: The configured title, nil for the action's own.
    public func makeConfiguredContextItem(for id: ActionID, target: ActionTargetRef?, title: String?) -> NSMenuItem? {
        guard let item = makeMenuItem(for: id) else { return nil }
        let invocation = ActionInvocation(target: target)
        item.representedObject = ActionMenuPayload(id: canonicalID(for: id), target: target)
        item.image = descriptor(for: id).flatMap { Self.menuIcon($0.symbol) }
        ActionTargetTitles.decorate(item, id: canonicalID(for: id), invocation: invocation, in: self)
        if let title { item.title = title }
        return item
    }
}
