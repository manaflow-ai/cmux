import CmuxNextCompat

/// A client-only top item and its look (`SidebarModel.transientTopItems`). Never in the layout
/// document: it cannot be moved, edited or hidden, and activates like any item.
public nonisolated struct SidebarTransientItem: Hashable, Sendable {
    public var item: LayoutItem
    public var info: SidebarItemInfo
    /// The items it draws right after, in order of preference (the first one the band shows):
    /// in that item's section, with that section's look. Empty, or none of them shown: it draws
    /// in the transient section at the top of the band.
    public var after: [LayoutItemRef]
    /// Draws only right after one of `after` (a Chief subagent under the Chief item): none of them
    /// shown, it does not draw at all.
    public var anchoredOnly: Bool

    /// `id` must carry the `client.` prefix (`LayoutItemID.isTransient`).
    public init(id: LayoutItemID, info: SidebarItemInfo, after: [LayoutItemRef] = [], anchoredOnly: Bool = false) {
        item = LayoutItem(id: id, ref: LayoutItemRef(kind: "client", value: id.rawValue))
        self.info = info
        self.after = after
        self.anchoredOnly = anchoredOnly
    }
}

extension SidebarTransientItem {
    /// The Channels entry (hq-6d cx-frn2y; Lawrence 2026-10-15: "2 diff things in section like Home and
    /// Channels, where u have to cmd shift p to enable channels in the first place"): right after Home,
    /// shown while `home.channelsEnabled` is on. The App activates it (`home.switchView` channels).
    public static let channelsID = LayoutItemID(LayoutItemID.transientPrefix + "channels")

    @MainActor public static var channels: SidebarTransientItem {
        SidebarTransientItem(id: channelsID, info: SidebarItemInfo(title: SectionStrings.channels, symbol: "number"),
                             after: [SidebarLayoutDocument.homeRef, .builtIn(.home)])
    }
}

extension SidebarModel {
    /// `sections` (a band's shown sections) with the transient items placed: each anchored item right
    /// after the first of its `after` items that `sections` show; the others, unless `anchoredOnly`, in
    /// one untitled section first (built-in look, one row per item).
    ///
    /// An item may anchor after one placed before it (a machine's chats after its header, each after the
    /// last), and one placed later after the same item goes right after it, before the earlier ones. So
    /// the items form a tree under the shown items, each node's children newest first, and the band is its
    /// walk in order: one pass over the shown items and one per transient item, O(rows), where inserting
    /// each item into the list it searched again was O(rows²) (2,000 attached sessions' rows).
    func placingTransientItems(in sections: [LayoutSection], anchoredOnly: Bool = false) -> [LayoutSection] {
        let transients = transientTopItems
        guard !transients.isEmpty else { return sections }
        // Nodes: the shown items in order (0..<shownCount), then the transient items (shownCount + k).
        var node: [LayoutItemRef: Int] = [:]
        var shownCount = 0
        for section in sections {
            for item in section.items {
                if node[item.ref] == nil { node[item.ref] = shownCount }
                shownCount += 1
            }
        }
        var visited = shownCount
        var children: [Int: [Int]] = [:]
        var loose: [LayoutItem] = []
        for (k, transient) in transients.enumerated() {
            visited += 1
            guard let anchor = transient.after.lazy.compactMap({ node[$0] }).first else {
                if !transient.anchoredOnly { loose.append(transient.item) }
                continue
            }
            children[anchor, default: []].append(shownCount + k)
            if node[transient.item.ref] == nil { node[transient.item.ref] = shownCount + k }
        }
        var placed = sections
        if !children.isEmpty {
            var at = 0
            for s in sections.indices {
                let range = at..<(at + sections[s].items.count)
                at = range.upperBound
                guard range.contains(where: { children[$0] != nil }) else { continue }
                var items: [LayoutItem] = []
                items.reserveCapacity(sections[s].items.count)
                for (offset, item) in sections[s].items.enumerated() {
                    items.append(item)
                    // The anchor's subtree in order: a stack of nodes whose children come newest first.
                    var stack = children[range.lowerBound + offset] ?? []
                    while let next = stack.popLast() {
                        visited += 1
                        items.append(transients[next - shownCount].item)
                        stack += children[next] ?? []
                    }
                }
                placed[s].items = items
            }
        }
        ScaleWork.add(.bandRows, visited)
        guard !anchoredOnly, !loose.isEmpty else { return placed }
        return [LayoutSection(id: LayoutSectionID(LayoutItemID.transientPrefix + "top"), showsTitle: false,
                              region: .top, look: .builtIn, items: loose)] + placed
    }
}
