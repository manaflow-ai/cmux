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

    /// The person's choice wins, else Chiefs and owner pins are pinned (`inbox.pins_is_pinned`).
    public func isPinned(_ row: InboxRow) -> Bool {
        HomeInboxRules().call("pins_is_pinned", RowRequest(pins: rules, row: HomeInboxRules.Row(row), on: false), fallback: false)
    }

    /// `rows` as the list shows them: the pinned rows (the user's pins in their order, then default
    /// pins in `rows` order), and the others newest first (ties by id) (`inbox.pins_split`).
    public func split(_ rows: [InboxRow]) -> (pinned: [InboxRow], rest: [InboxRow]) {
        let reply = HomeInboxRules().call("pins_split", RowsRequest(pins: rules, rows: HomeInboxRules().rows(rows)),
                                        fallback: SplitReply(pinned: [], rest: rows.map(\.id.rawValue)))
        return (HomeInboxRules().pick(reply.pinned, from: rows), HomeInboxRules().pick(reply.rest, from: rows))
    }

    /// Pins `row` (at the end of the user's order) or unpins it. A row already pinned keeps its place
    /// (`inbox.pins_set_pinned`).
    public mutating func setPinned(_ on: Bool, _ row: InboxRow) {
        apply(HomeInboxRules().call("pins_set_pinned", RowRequest(pins: rules, row: HomeInboxRules.Row(row), on: on), fallback: rules))
    }

    /// Puts `id` at `index` of the grid's order (an index after `id` left its old place, clamped)
    /// and pins it: a pinned tile dragged to a new place, or a row dropped into the grid.
    /// `shown` is the grid as it is shown now, default pins included (`inbox.pins_place`).
    public mutating func place(_ id: ConversationID, at index: Int, shown: [ConversationID]) {
        let request = PlaceRequest(pins: rules, id: id.rawValue, index: index, shown: shown.map(\.rawValue))
        apply(HomeInboxRules().call("pins_place", request, fallback: rules))
    }

    /// Pins `order` in that order before the other pins kept here, each at the matching entry of
    /// `positions` when given (a drop numbers the whole grid, the owners' pins too) (`inbox.pins_arrange`).
    public mutating func arrange(_ order: [ConversationID], positions numbered: [UInt64] = []) {
        let request = ArrangeRequest(pins: rules, order: order.map(\.rawValue), positions: numbered)
        apply(HomeInboxRules().call("pins_arrange", request, fallback: rules))
    }

    /// The main Chief leads the grid only while the person has not placed it themselves (a pin of
    /// theirs, or a drag): returns `main` then, else nil (`inbox.pins_leading`).
    public func leading(_ main: ConversationID?) -> ConversationID? {
        let id: String? = HomeInboxRules().call("pins_leading", LeadingRequest(pins: rules, main: main?.rawValue), fallback: nil)
        return id.map(ConversationID.init(rawValue:))
    }

    private var rules: HomeInboxRules.Pins {
        HomeInboxRules.Pins(pinned: pinned.map(\.rawValue), unpinned: unpinned.map(\.rawValue).sorted(), positions: positions)
    }

    private mutating func apply(_ pins: HomeInboxRules.Pins) {
        pinned = pins.pinned.map(ConversationID.init(rawValue:))
        unpinned = Set(pins.unpinned.map(ConversationID.init(rawValue:)))
        positions = pins.positions
    }
}

private nonisolated struct RowRequest: Encodable {
    var pins: HomeInboxRules.Pins
    var row: HomeInboxRules.Row
    var on: Bool
}

private nonisolated struct RowsRequest: Encodable {
    var pins: HomeInboxRules.Pins
    var rows: [HomeInboxRules.Row]
}

private nonisolated struct SplitReply: Decodable {
    var pinned: [String]
    var rest: [String]
}

private nonisolated struct PlaceRequest: Encodable {
    var pins: HomeInboxRules.Pins
    var id: String
    var index: Int
    var shown: [String]
}

private nonisolated struct ArrangeRequest: Encodable {
    var pins: HomeInboxRules.Pins
    var order: [String]
    var positions: [UInt64]
}

private nonisolated struct LeadingRequest: Encodable {
    var pins: HomeInboxRules.Pins
    var main: String?
}
