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
    func placingTransientItems(in sections: [LayoutSection], anchoredOnly: Bool = false) -> [LayoutSection] {
        var placed = sections
        var loose: [LayoutItem] = []
        for transient in transientTopItems {
            guard let (s, i) = Self.anchor(transient.after, in: placed) else {
                if !transient.anchoredOnly { loose.append(transient.item) }
                continue
            }
            placed[s].items.insert(transient.item, at: i + 1)
        }
        guard !anchoredOnly, !loose.isEmpty else { return placed }
        return [LayoutSection(id: LayoutSectionID(LayoutItemID.transientPrefix + "top"), showsTitle: false,
                              region: .top, look: .builtIn, items: loose)] + placed
    }

    private static func anchor(_ refs: [LayoutItemRef], in sections: [LayoutSection]) -> (Int, Int)? {
        for ref in refs {
            for (s, section) in sections.enumerated() {
                if let i = section.items.firstIndex(where: { $0.ref == ref }) { return (s, i) }
            }
        }
        return nil
    }
}
