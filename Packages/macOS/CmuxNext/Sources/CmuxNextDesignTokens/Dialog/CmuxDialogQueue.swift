/// Which dialogs show: one at a time per scope, in the order they were
/// asked; the next one in a scope shows when the visible one ends. Pure,
/// so the order rule is tested without windows.
public nonisolated struct CmuxDialogQueue<Scope: Hashable>: Sendable where Scope: Sendable {
    public private(set) var order: [(id: Int, scope: Scope)] = []

    public init() {}

    /// Adds `id`; true when it shows at once (nothing else in its scope).
    public mutating func enqueue(_ id: Int, in scope: Scope) -> Bool {
        let showsNow = !order.contains { $0.scope == scope }
        order.append((id, scope))
        return showsNow
    }

    /// Removes `id`; returns the dialog that shows next in its scope, when
    /// `id` was the visible one.
    public mutating func remove(_ id: Int) -> Int? {
        guard let index = order.firstIndex(where: { $0.id == id }) else { return nil }
        let scope = order[index].scope
        let wasVisible = visible(in: scope) == id
        order.remove(at: index)
        return wasVisible ? visible(in: scope) : nil
    }

    /// The dialog showing in `scope`.
    public func visible(in scope: Scope) -> Int? {
        order.first { $0.scope == scope }?.id
    }

    public func isVisible(_ id: Int) -> Bool {
        order.first { $0.id == id }.map { visible(in: $0.scope) == id } ?? false
    }

    public func ids(in scope: Scope) -> [Int] {
        order.filter { $0.scope == scope }.map(\.id)
    }
}
