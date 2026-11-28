import CmuxNextDesign

/// The `sidebar_item_order` op of `cmux_layout_reducer_json` (cmux-layout-reducer sidebar_item_order.rs): which laid-out
/// rows are stops, which band items count before the list, where a workspace with no stop of its own draws, and what
/// Cmd-1...9, a digit hint and Cmd-Ctrl-[ / ] select. Swift lays the list out and keeps the cache; Rust decides.
nonisolated enum RustSidebarItemOrder {
    /// One destination on the wire: `{"top_item": id}`, `{"group": id}` or `{"workspace": id}`.
    struct Item: Codable, Hashable {
        var top_item: String?
        var group: String?
        var workspace: String?

        init(_ item: SidebarItem) {
            switch item {
            case let .topItem(id): top_item = id.rawValue
            case let .group(id): group = id.rawValue
            case let .workspace(id): workspace = id.rawValue
            }
        }

        var item: SidebarItem? {
            if let top_item { return .topItem(LayoutItemID(top_item)) }
            if let group { return .group(GroupID(group)) }
            if let workspace { return .workspace(WorkspaceID(workspace)) }
            return nil
        }
    }

    struct Order: Codable {
        var top_items: [Item]
        var rows: [Item]
        var stops: [String: Item]

        init(_ order: SidebarItemOrder) {
            top_items = order.topItems.map(Item.init)
            rows = order.rows.map(Item.init)
            stops = Dictionary(uniqueKeysWithValues: order.stops.map { ($0.key.rawValue, Item($0.value)) })
        }

        var order: SidebarItemOrder {
            var stopsByWorkspace: [WorkspaceID: SidebarItem] = [:]
            for (id, item) in stops { stopsByWorkspace[WorkspaceID(id)] = item.item }
            return SidebarItemOrder(topItems: top_items.compactMap(\.item), rows: rows.compactMap(\.item), stops: stopsByWorkspace)
        }
    }

    struct Settings: Encodable {
        var numbering: String
        var cmd9: String
        var stepping: String
        var steppingWraps: Bool

        init(_ settings: SidebarNavigationSettings) {
            numbering = settings.numbering.rawValue
            cmd9 = settings.cmd9.rawValue
            stepping = settings.stepping.rawValue
            steppingWraps = settings.steppingWraps
        }
    }

    /// A laid-out row key the rules read (`workspace`, `item`, `block`, `group`); other kinds are no stop and stay home.
    struct RowKey: Encodable {
        var kind: String
        var id: String

        init?(_ key: SidebarRowKey) {
            switch key {
            case let .workspace(id): (kind, self.id) = ("workspace", id.rawValue)
            case let .item(id): (kind, self.id) = ("item", id)
            case let .block(id): (kind, self.id) = ("block", id)
            case let .group(id): (kind, self.id) = ("group", id.rawValue)
            default: return nil
            }
        }
    }

    struct Group: Encodable {
        var collapsed: Bool
        var members: [String]
    }

    /// What the order is made of (`Source`).
    struct Make: Encodable {
        let op = "make"
        var rows: [RowKey]
        var selectable: [String]
        var collapsed_blocks: [String]
        var groups: [String: Group]
        var top: [String]
        var in_block: [String: [String]]
        var listed: [String]
    }

    private struct DrawnPlace: Encodable {
        let op = "drawn_place"
        var order_rows: [Item]
        var drawn: [Item]
        var id: String
    }

    private struct Pick: Encodable {
        let op = "pick"
        var order: Order
        var number: Int
        var settings: Settings
    }

    private struct Number: Encodable {
        let op = "number"
        var order: Order
        var item: Item
        var settings: Settings
    }

    private struct Step: Encodable {
        let op = "step"
        var order: Order
        var selected: Item?
        var offset: Int
        var settings: Settings
        var place: Int?
    }

    private struct Stop: Encodable {
        let op = "stop"
        var order: Order
        var item: Item?
    }

    private struct ItemReply: Decodable { var item: Item? }
    private struct NumberReply: Decodable { var number: Int? }
    private struct PlaceReply: Decodable { var place: Int? }
    private struct StopReply: Decodable { var stop: Item?; var reveals_top: Bool }

    private static func call<Request: Encodable, Response: Decodable>(_ request: Request, as: Response.Type) -> Response? {
        RustSidebarClient.call("sidebar_item_order", request, as: Response.self)
    }

    /// The order made of `source`; nil when the reducer refuses it.
    static func make(_ source: Make) -> SidebarItemOrder? {
        call(source, as: Order.self)?.order
    }

    /// Where `id` draws among `orderRows` when it is active (`drawn`: the stops laid out with it active); nil when even
    /// then it draws nowhere.
    static func drawnPlace(of id: WorkspaceID, orderRows: [SidebarItem], drawn: [SidebarItem]) -> Int? {
        call(DrawnPlace(order_rows: orderRows.map(Item.init), drawn: drawn.map(Item.init), id: id.rawValue), as: PlaceReply.self)?.place
    }

    static func pick(_ number: Int, in order: SidebarItemOrder, _ settings: SidebarNavigationSettings) -> SidebarItem? {
        call(Pick(order: Order(order), number: number, settings: Settings(settings)), as: ItemReply.self)?.item?.item
    }

    static func number(for item: SidebarItem, in order: SidebarItemOrder, _ settings: SidebarNavigationSettings) -> Int? {
        call(Number(order: Order(order), item: Item(item), settings: Settings(settings)), as: NumberReply.self)?.number
    }

    static func step(from selected: SidebarItem?, by offset: Int, in order: SidebarItemOrder, _ settings: SidebarNavigationSettings,
                     place: Int?) -> SidebarItem? {
        call(Step(order: Order(order), selected: selected.map(Item.init), offset: offset, settings: Settings(settings), place: place),
             as: ItemReply.self)?.item?.item
    }

    /// The stop `item` is at, and whether selecting it shows the list from its very top.
    static func stop(for item: SidebarItem?, in order: SidebarItemOrder) -> (stop: SidebarItem?, revealsTop: Bool) {
        guard let reply = call(Stop(order: Order(order), item: item.map(Item.init)), as: StopReply.self) else { return (nil, false) }
        return (reply.stop?.item, reply.reveals_top)
    }
}
