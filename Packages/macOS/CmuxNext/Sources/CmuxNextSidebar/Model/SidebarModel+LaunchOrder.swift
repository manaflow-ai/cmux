import Foundation

/// The launch order hold (Leo, 2026-11-09: "tens of seconds after restarting to update the sidebar kinda reshuffled or
/// something weird"). Until the home session's owner serves (`holdsLaunchOrder`, set by the app), each structural set
/// keeps the rows drawn so far in their places; the rule is Rust's (`sidebar_launch_order` of
/// `cmux_layout_reducer_json`). Its lists: the section order, each section's top-level rows (a nested group moves with
/// the group it sits under), and each group's members. A pass that follows the person's own request shows as asked and
/// becomes the held order. Ending the hold shows the last pass's live order in one structural set.
extension SidebarModel {
    /// The held and live orders by list key, while the hold is on.
    struct LaunchOrderLists: Equatable {
        var references: [String: [String]] = [:]
        var live: [String: [String]] = [:]
    }

    /// `next` in the order held so far; `next` itself while the hold is off.
    func holdingLaunchOrder(_ next: [SidebarSection]) -> [SidebarSection] {
        guard holdsLaunchOrder else { return next }
        let lists = Self.launchOrderLists(next)
        let adopt = followsUserIntent
        let request = LaunchOrderRequest(hold: true, lists: lists.map {
            LaunchOrderRequest.List(key: $0.key, reference: adopt ? [] : launchOrder.references[$0.key] ?? [], next: $0.keys)
        })
        for list in lists { launchOrder.live[list.key] = list.keys }
        guard let reply = RustSidebarClient.call("sidebar_launch_order", request, as: LaunchOrderReply.self) else { return next }
        var orders: [String: [String]] = [:]
        for list in reply.lists {
            launchOrder.references[list.key] = list.reference
            orders[list.key] = list.order
        }
        return Self.arranging(next, orders)
    }

    /// The hold starts: the rows drawn now are the order to keep (the window's saved rows when it starts at launch).
    func startLaunchOrderHold() {
        launchOrder = LaunchOrderLists()
        for list in Self.launchOrderLists(sections) { launchOrder.references[list.key] = list.keys }
    }

    /// The owner serves: the rows take the last pass's live order, then the hold forgets what it held.
    func endLaunchOrderHold() {
        let live = launchOrder.live
        launchOrder = LaunchOrderLists()
        guard !live.isEmpty else { return }
        sections = Self.arranging(sections, live)
    }

    // MARK: Lists

    private static func key(_ id: SectionID) -> String {
        switch id {
        case .pinned: "pinned"
        case let .machine(machine): "m:" + machine.rawValue
        case let .custom(custom): "c:" + custom
        }
    }

    private static func key(_ node: SidebarNode) -> String {
        switch node {
        case let .workspace(ws): "w:" + ws.id.rawValue
        case let .group(group): "g:" + group.id.rawValue
        case let .item(item): "i:" + item.id
        }
    }

    /// A section's top-level rows: each node with the nested groups listed under it (a group whose parent the run holds).
    private static func units(_ nodes: [SidebarNode]) -> [[SidebarNode]] {
        var units: [[SidebarNode]] = []
        var groups: Set<GroupID> = []
        for node in nodes {
            if case let .group(group) = node, let parent = group.parent, groups.contains(parent), !units.isEmpty {
                units[units.count - 1].append(node)
                groups.insert(group.id)
                continue
            }
            units.append([node])
            groups = []
            if case let .group(group) = node { groups.insert(group.id) }
        }
        return units
    }

    static func launchOrderLists(_ sections: [SidebarSection]) -> [(key: String, keys: [String])] {
        var lists: [(key: String, keys: [String])] = [("sections", sections.map { key($0.id) })]
        for section in sections {
            let sectionKey = key(section.id)
            lists.append((sectionKey, units(section.nodes).map { key($0[0]) }))
            for case let .group(group) in section.nodes {
                lists.append((sectionKey + "/" + key(.group(group)), group.workspaces.map { "w:" + $0.id.rawValue }))
            }
        }
        return lists
    }

    /// `sections` with each list in `orders` drawn in its order; a list whose order does not name the same rows stays.
    static func arranging(_ sections: [SidebarSection], _ orders: [String: [String]]) -> [SidebarSection] {
        let arranged = sections.map { section -> SidebarSection in
            var section = section
            let sectionKey = key(section.id)
            let rows = units(section.nodes)
            section.nodes = reordered(rows, keys: rows.map { key($0[0]) }, to: orders[sectionKey]).flatMap { $0 }
            section.nodes = section.nodes.map { node in
                guard case var .group(group) = node else { return node }
                group.workspaces = reordered(group.workspaces, keys: group.workspaces.map { "w:" + $0.id.rawValue },
                                             to: orders[sectionKey + "/" + key(node)])
                return .group(group)
            }
            return section
        }
        return reordered(arranged, keys: arranged.map { key($0.id) }, to: orders["sections"])
    }

    private static func reordered<T>(_ items: [T], keys: [String], to order: [String]?) -> [T] {
        guard let order, order != keys, order.count == items.count else { return items }
        var byKey: [String: T] = [:]
        for (key, item) in zip(keys, items) {
            guard byKey.updateValue(item, forKey: key) == nil else { return items } // a key listed twice: rows not told apart
        }
        let result = order.compactMap { byKey[$0] }
        return result.count == items.count ? result : items
    }
}

/// `sidebar_launch_order`'s request (cmux-layout-reducer sidebar_launch_order.rs).
nonisolated struct LaunchOrderRequest: Encodable {
    struct List: Encodable {
        var key: String
        var reference: [String]
        var next: [String]
    }

    var hold: Bool
    var lists: [List]
}

/// `sidebar_launch_order`'s reply.
nonisolated struct LaunchOrderReply: Decodable {
    struct List: Decodable {
        var key: String
        var order: [String]
        var reference: [String]
    }

    var lists: [List]
}
