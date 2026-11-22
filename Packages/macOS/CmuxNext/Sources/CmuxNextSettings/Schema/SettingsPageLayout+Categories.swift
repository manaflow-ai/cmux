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

    /// `#/settings/CATEGORY?focus=card.NAME` for an `openSettings` `setting: card.NAME` whose card sits
    /// in a category no section opens (no alias: Settings > Customize, which the App Store's Customize
    /// cmux… card opens with `card.customizeChecklist`), else nil: `SettingsAnchor`'s section route.
    public static func pageOnlyCardRoute(_ setting: String?) -> String? {
        guard let setting, setting.hasPrefix("card."),
              let card = Card(rawValue: String(setting.dropFirst("card.".count))),
              let category = sidebarSections.flatMap(\.categories)
                  .first(where: { $0.lead.contains(card) || $0.trail.contains(card) }),
              category.aliases.isEmpty else { return nil }
        return "#/settings/\(category.id)?focus=\(setting)"
    }
}
