extension SettingsPageLayout {
    /// The categories with their cards resolved against `rows`: only rows the
    /// page shows, empty cards dropped, lead keys first, then schema-group rows in schema order.
    /// The layout itself is data (schemas/settings/source/page-layout.json, generated into
    /// SettingsSchema+PageLayout*.generated.swift); this resolves it against the rows.
    public func categories(rows: [SettingDescriptor] = SettingsSchema.all) -> [Category] {
        let shown = rows.filter(\.isShownOnSettingsPage)
        let specs = Self.specs
        let claimed = Set(specs.flatMap { $0.groups.flatMap { $0.leadKeys + $0.keys } })
        let ids = Set(shown.map(\.id))
        return specs.map { spec in
            let groups = spec.groups.enumerated().compactMap { index, group -> Group? in
                let own = group.group.map { key in
                    shown.filter { $0.textKeys.group == key && !claimed.contains($0.id) }.map(\.id)
                } ?? []
                let moved = group.keys.filter(ids.contains)
                let rows = group.leadKeys.filter(ids.contains) + own + moved
                let title = group.title ?? group.group.flatMap { key in
                    shown.first { $0.textKeys.group == key }.map { SettingText(key: key, text: $0.group) }
                }
                guard !rows.isEmpty, let title else { return nil }
                return Group(key: group.group ?? "\(spec.id).\(index)", title: title, rows: rows)
            }
            return Category(spec: spec, groups: groups)
        }
    }

    /// `#/settings/CATEGORY?focus=card.NAME` for an `openSettings` `setting: card.NAME` (or
    /// `card.NAME.PART`, a place inside the card) whose card the page layout places in CATEGORY's lead
    /// or trail, else nil. The page's link resolver (webviews settingsLinks.ts) opens the category and
    /// scrolls to the card. WindowHandlers asks for it when `SettingsAnchor` knows no such card: Settings >
    /// Customize's checklist (the App Store's Customize cmux… card), and a card of a section's category
    /// such as Appearance's Looks gallery (`card.looksGallery`, which the What's New tour opens; before
    /// this the action refused it, "no setting card.looksGallery in Settings").
    public static func cardRoute(_ setting: String?) -> String? {
        guard let setting, setting.hasPrefix("card."),
              let name = setting.dropFirst("card.".count).split(separator: ".", maxSplits: 1).first,
              let card = Card(rawValue: String(name)),
              let category = sidebarSections.flatMap(\.categories)
                  .first(where: { $0.lead.contains(card) || $0.trail.contains(card) }) else { return nil }
        return "#/settings/\(category.id)?focus=\(setting)"
    }
}
