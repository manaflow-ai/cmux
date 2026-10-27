import CmuxNextActions

/// The catalog's palette order (`ActionDescriptor.paletteTier`, `paletteFamilies`;
/// plans/cmux-next/palette-ranking.md 5.4): no row is dropped. A family's members fold into one
/// row on the empty query and still match a typed query; daily rows lead their section, niche
/// rows close it, and rows the focused pane cannot run come last, dimmed with the reason.
extension RegistryPaletteProvider {
    /// Ahead of or behind an equal match while typing: less than a match tier, so a better
    /// match of a niche row still wins.
    static let dailyRankBias = 120
    static let nicheRankBias = -120

    static func rankBias(for tier: PaletteTier) -> Int {
        switch tier {
        case .daily: dailyRankBias
        case .standard: 0
        case .niche: nicheRankBias
        }
    }

    /// `items` with each family folded into its row, ordered enabled before disabled, then daily,
    /// standard, niche (a stable sort: the empty query lists each section's rows in this order).
    /// `tiers` is by item id.
    static func arranged(_ items: [PaletteItem], tiers: [String: PaletteTier]) -> [PaletteItem] {
        var items = items
        var position: [ActionID: Int] = [:]
        for (index, item) in items.enumerated() {
            if let id = item.actionID { position[id] = index }
        }
        var familyRows: [(at: Int, row: PaletteItem)] = []
        for family in ActionDescriptor.paletteFamilies {
            let present = family.members.compactMap { position[$0] }
            guard let first = present.min() else { continue }
            if let parent = family.parent {
                // Without its parent row the members stay listed.
                guard let at = position[parent] else { continue }
                items[at].keywords += present.map { items[$0].title }
            } else {
                familyRows.append((first, familyRow(family, members: present.map { items[$0] })))
            }
            for index in present { items[index].hidesWhenQueryEmpty = true }
        }
        for (at, row) in familyRows.sorted(by: { $0.at > $1.at }) { items.insert(row, at: at) }
        return items.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.isEnabled != rhs.element.isEnabled { return lhs.element.isEnabled }
                let left = tiers[lhs.element.id] ?? .standard
                let right = tiers[rhs.element.id] ?? .standard
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The row that opens a page of the family's members, in their section. The page is built
    /// when the row runs, not on every open.
    static func familyRow(_ family: PaletteFamily, members: [PaletteItem]) -> PaletteItem {
        let id = "family:\(family.id)"
        return PaletteItem(
            id: id,
            title: family.title,
            symbol: family.symbol,
            section: members[0].section,
            keywords: members.map(\.title),
            isEnabled: members.contains(where: \.isEnabled),
            primary: PaletteCommand(id: "run", title: PaletteStrings.open, symbol: "return",
                                    effect: .deferred { .push(Self.familyPage(family, members: members)) }),
            frecencyKey: id
        )
    }

    /// The members, the ones the focused pane can run first.
    static func familyPage(_ family: PaletteFamily, members: [PaletteItem]) -> PalettePageSpec {
        let listed = members.map { member in
            var member = member
            member.hidesWhenQueryEmpty = false
            return member
        }
        let id = "family:\(family.id)"
        return PalettePageSpec(
            id: id,
            title: family.title,
            placeholder: PaletteStrings.searchPlaceholder,
            symbol: family.symbol,
            providers: [StaticPaletteProvider(id: id, items: listed.filter(\.isEnabled) + listed.filter { !$0.isEnabled })]
        )
    }
}
