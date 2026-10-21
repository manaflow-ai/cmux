/// Which terminal tabs keep a live surface and an attached session: the
/// `limit` most recently shown. A tab shown again while warm switches with
/// no reattach and no new surface; one that falls out is cooled (its
/// session detaches, its surface goes) and keeps its last frame, which the
/// page shows at once while it reattaches in the background.
public struct TerminalWarmSet<ID: Hashable & Sendable>: Sendable {
    public let limit: Int
    /// Least recently shown first.
    public private(set) var order: [ID] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// `id` is on screen now. Returns the tabs to cool, least recent first
    /// (never `id` itself).
    public mutating func touch(_ id: ID) -> [ID] {
        order.removeAll { $0 == id }
        order.append(id)
        guard order.count > limit else { return [] }
        let cooled = Array(order.prefix(order.count - limit))
        order.removeFirst(cooled.count)
        return cooled
    }

    /// The tab closed (or its host went another way): it no longer counts.
    public mutating func remove(_ id: ID) {
        order.removeAll { $0 == id }
    }

    public func contains(_ id: ID) -> Bool {
        order.contains(id)
    }
}
