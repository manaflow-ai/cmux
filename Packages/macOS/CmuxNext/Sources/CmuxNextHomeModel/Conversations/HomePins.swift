public import CmuxHomeCore
import Foundation

/// Which conversations are pinned (the Home sidebar's grid). Client side,
/// per account, until the daemon's cloud proxy forwards `inbox.pin`
/// (home-cloud-proxy.md 8; the local owner refuses pins too): `pinned` is
/// the user's order; Chiefs and owner-pinned conversations are pinned by
/// default unless the user unpinned them (`unpinned`). A drag in the grid
/// (`place`) writes the whole shown order into `pinned`, default pins included, and gives each
/// pin the position the drop gave the grid (``positions``), so this Mac's pins and the owners'
/// pins keep one order in a grid that holds both.
public struct HomePins: Hashable, Sendable, Codable {
    public var pinned: [ConversationID]
    public var unpinned: Set<ConversationID>
    /// The grid position of each of these pins the last drag numbered (the owners' scale:
    /// milliseconds since 1970 plus the tile's index), by conversation id. A pin without one
    /// (pinned, never dragged) sorts after every numbered pin.
    public var positions: [String: UInt64]

    public init(pinned: [ConversationID] = [], unpinned: Set<ConversationID> = [], positions: [String: UInt64] = [:]) {
        self.pinned = pinned
        self.unpinned = unpinned
        self.positions = positions
    }

    private enum CodingKeys: String, CodingKey { case pinned, unpinned, positions }

    /// Pins saved before ``positions`` existed decode with none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try container.decode([ConversationID].self, forKey: .pinned)
        unpinned = try container.decode(Set<ConversationID>.self, forKey: .unpinned)
        positions = try container.decodeIfPresent([String: UInt64].self, forKey: .positions) ?? [:]
    }

    /// The position the last drag gave `id`, or nil (never dragged, or not pinned here).
    public func position(of id: ConversationID) -> UInt64? { positions[id.rawValue] }

    public func isPinned(_ row: InboxRow) -> Bool {
        if pinned.contains(row.id) { return true }
        if unpinned.contains(row.id) { return false }
        return row.kind == .chief || row.isPinned
    }

    /// `rows` as the list shows them: the pinned rows (the user's pins in their order, then default
    /// pins in `rows` order), and the others newest first (ties by id).
    public func split(_ rows: [InboxRow]) -> (pinned: [InboxRow], rest: [InboxRow]) {
        let order = Dictionary(pinned.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let pinnedRows = rows.filter { isPinned($0) }.enumerated()
            .sorted { (order[$0.element.id] ?? Int.max, $0.offset) < (order[$1.element.id] ?? Int.max, $1.offset) }.map(\.element)
        let rest = rows.filter { !isPinned($0) }.sorted { a, b in
            a.timestamp != b.timestamp ? a.timestamp > b.timestamp : a.id.rawValue < b.id.rawValue
        }
        return (pinnedRows, rest)
    }

    /// Pins `row` (at the end of the user's order) or unpins it. A row already pinned keeps its place.
    public mutating func setPinned(_ on: Bool, _ row: InboxRow) {
        if on, isPinned(row) { return }
        pinned.removeAll { $0 == row.id }
        unpinned.remove(row.id)
        positions.removeValue(forKey: row.id.rawValue)
        if on { pinned.append(row.id) } else if row.kind == .chief || row.isPinned { unpinned.insert(row.id) }
    }

    /// Puts `id` at `index` of the grid's order (an index after `id` left its old place, clamped)
    /// and pins it: a pinned tile dragged to a new place, or a row dropped into the grid.
    /// `shown` is the grid as it is shown now, default pins included.
    public mutating func place(_ id: ConversationID, at index: Int, shown: [ConversationID]) {
        var order = shown.filter { $0 != id }
        order.insert(id, at: min(max(0, index), order.count))
        arrange(order)
    }

    /// Pins `order` in that order before the other pins kept here, each at the matching entry of
    /// `positions` when given (a drop numbers the whole grid, the owners' pins too).
    public mutating func arrange(_ order: [ConversationID], positions numbered: [UInt64] = []) {
        let placed = Set(order)
        pinned = order + pinned.filter { !placed.contains($0) }
        unpinned.subtract(placed)
        for (id, position) in zip(order, numbered) { positions[id.rawValue] = position }
    }

    /// The main Chief leads the grid only while the person has not placed it themselves (a pin of
    /// theirs, or a drag): returns `main` then, else nil.
    public func leading(_ main: ConversationID?) -> ConversationID? {
        guard let main, !pinned.contains(main) else { return nil }
        return main
    }
}
