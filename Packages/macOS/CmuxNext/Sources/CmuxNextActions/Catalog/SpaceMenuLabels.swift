// Menu-only row titles of the space menu (SIDEBAR-FOOTER-AND-SPACE-MENU F3,
// Arc's wording). The palette and the CLI keep the actions' own titles
// ("Set Space Color…"), which name the object; in the space's own menu the
// object is clear. Strings live in ProfileActions.xcstrings.

nonisolated enum SpaceMenuLabels {
    static var changeIcon: String { text("menu.space.changeIcon", "Change Space Icon…") }
    static var removeIcon: String { text("menu.space.removeIcon", "Remove Space Icon") }
    static var editThemeColor: String { text("menu.space.editThemeColor", "Edit Theme Color…") }
    static var setBrowserProfile: String { text("menu.space.setBrowserProfile", "Set Browser Profile…") }
    static var newGroup: String { text("menu.space.newGroup", "New Group") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ProfileActions", bundle: .module)
    }
}
