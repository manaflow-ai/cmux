/// Places of a list (indexes), kept in ascending order: which items of a list hold a key, or have something to
/// show. An owner that joins the items of a session-sized list (``ObservedItems``) keeps one of these per key, so
/// one item's change finds the first holder of a key, or the few items to show, with no pass over the list.
///
/// ``insert(_:)`` and ``remove(_:)`` find the place by binary search and then move the places after it (a block
/// move of integers): the cost follows the holders of ONE key, never the length of the list.
public struct SortedPositions: Sendable, Equatable {
    /// The places, ascending, each once.
    public private(set) var positions: [Int] = []

    /// No place.
    public init() {}

    /// The first (lowest) place; nil when there is none.
    public var first: Int? { positions.first }

    /// True when there is no place.
    public var isEmpty: Bool { positions.isEmpty }

    /// How many places there are.
    public var count: Int { positions.count }

    /// Adds `position` (nothing when it is there already).
    public mutating func insert(_ position: Int) {
        let index = lowerBound(position)
        guard index == positions.count || positions[index] != position else { return }
        positions.insert(position, at: index)
    }

    /// Takes `position` out (nothing when it is not there).
    public mutating func remove(_ position: Int) {
        let index = lowerBound(position)
        guard index < positions.count, positions[index] == position else { return }
        positions.remove(at: index)
    }

    /// The index of the first place that is not below `position`.
    private func lowerBound(_ position: Int) -> Int {
        var (low, high) = (0, positions.count)
        while low < high {
            let middle = (low + high) / 2
            if positions[middle] < position { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
