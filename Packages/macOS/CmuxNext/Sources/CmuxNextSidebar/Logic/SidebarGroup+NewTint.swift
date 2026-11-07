public import CmuxNextDesign

extension SidebarGroup {
    /// The color a new group takes (Leo 2026-11-06: "of course, like the automatic group colors"): under a palette the
    /// person chose (`sidebar.groupPalette`), the palette's next color, the one the fewest groups in `sections` have
    /// (`GroupColor.automatic`); under glass, the default, none: no color the person didn't choose.
    @MainActor public static func newTint(in sections: [SidebarSection],
                                          palette: GroupPalette = DesignSettings.shared.sidebarSections.groupPalette) -> GroupTint {
        guard palette.colorsNewGroups else { return .none }
        let existing = sections.flatMap(\.nodes).compactMap { node -> GroupTint? in
            if case let .group(group) = node { group.tint } else { nil }
        }
        return .palette(GroupColor.automatic(existing: existing))
    }
}
