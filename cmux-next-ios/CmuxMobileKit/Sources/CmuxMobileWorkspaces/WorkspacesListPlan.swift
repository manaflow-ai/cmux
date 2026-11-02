import Foundation

/// One section of a diffable list: its id and its items' ids, in order.
public struct ListSectionIDs: Equatable, Sendable {
    public var id: String
    public var items: [String]

    public init(id: String, items: [String]) {
        self.id = id
        self.items = items
    }

    /// `sections` with each item id kept only where it first appears (a
    /// diffable data source refuses a repeated id).
    public static func unique(_ sections: [ListSectionIDs]) -> [ListSectionIDs] {
        var seen = Set<String>()
        return sections.map { section in
            ListSectionIDs(id: section.id, items: section.items.filter { seen.insert($0).inserted })
        }
    }
}

/// What applying a new list model takes, worked out from the shown one: a
/// new snapshot only when the order changed, a reconfigure only for the rows
/// whose value changed, and whether rows came or went (the one change the
/// list animates on its own). O(rows) to compute, O(changed rows) to apply.
public struct ListApplyPlan: Equatable, Sendable {
    /// The sections or their items' order differ (a move, an insert, a removal).
    public var orderChanged: Bool
    /// An item id was added or removed.
    public var membershipChanged: Bool
    /// Items shown before and after whose value changed, in the new order.
    public var reconfigure: [String]

    public init(orderChanged: Bool, membershipChanged: Bool, reconfigure: [String]) {
        self.orderChanged = orderChanged
        self.membershipChanged = membershipChanged
        self.reconfigure = reconfigure
    }

    public var isEmpty: Bool { !orderChanged && reconfigure.isEmpty }

    public static func make<Item: Equatable>(old: [ListSectionIDs], oldItems: [String: Item],
                                             new: [ListSectionIDs], newItems: [String: Item]) -> ListApplyPlan {
        let orderChanged = old != new
        var membershipChanged = false
        if orderChanged {
            let oldCount = old.reduce(0) { $0 + $1.items.count }
            let newCount = new.reduce(0) { $0 + $1.items.count }
            membershipChanged = oldCount != newCount
                || new.contains { section in section.items.contains { oldItems[$0] == nil } }
        }
        var reconfigure: [String] = []
        for section in new {
            for id in section.items {
                guard let before = oldItems[id], let after = newItems[id], before != after else { continue }
                reconfigure.append(id)
            }
        }
        return ListApplyPlan(orderChanged: orderChanged, membershipChanged: membershipChanged, reconfigure: reconfigure)
    }
}
