/// Keyboard reordering of a whole tab group by one unit (a single tab or a
/// whole neighboring group). Indices follow `move-tab-group`: the insertion
/// index in the strip with the group's own tabs removed.
public nonisolated enum TabGroupReorder {
    /// One tab in strip order: its group and whether it is pinned.
    public struct Slot: Equatable, Sendable {
        public var group: String?
        public var pinned: Bool

        public init(group: String?, pinned: Bool = false) {
            self.group = group
            self.pinned = pinned
        }
    }

    /// The new index for `group`, or nil when it cannot move that way.
    /// Pinned tabs are never crossed.
    public static func targetIndex(of group: String, forward: Bool, in slots: [Slot]) -> Int? {
        guard let start = slots.firstIndex(where: { $0.group == group }) else { return nil }
        let rest = slots.filter { $0.group != group }
        if forward {
            guard start < rest.count else { return nil }
            var end = start
            if let neighbor = rest[start].group {
                while end + 1 < rest.count, rest[end + 1].group == neighbor { end += 1 }
            }
            return end + 1
        }
        guard start > 0, !rest[start - 1].pinned else { return nil }
        var begin = start - 1
        if let neighbor = rest[begin].group {
            while begin > 0, rest[begin - 1].group == neighbor { begin -= 1 }
        }
        return begin
    }
}
