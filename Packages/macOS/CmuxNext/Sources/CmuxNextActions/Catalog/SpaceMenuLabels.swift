// Menu-only row titles of the space menu (SIDEBAR-FOOTER-AND-SPACE-MENU F3,
// Arc's wording). The palette and the CLI keep the actions' own titles
// ("Set Space Color…"), which name the object; in the space's own menu the
// object is clear. Its icon and color rows use the shared words (`IconMenuLabels`,
// `ObjectMenuLabels.color`), as every other object's menu does. Strings live in ProfileActions.xcstrings.

nonisolated enum SpaceMenuLabels {
    static var setBrowserProfile: String { text("menu.space.setBrowserProfile", "Set Browser Profile…") }
    static var newGroup: String { text("menu.space.newGroup", "New Group") }
    static var newWorkspace: String { text("menu.space.newWorkspace", "New Workspace") }
    static var openInNewWindow: String { text("menu.space.openInNewWindow", "Open in New Window") }
    static var bringHere: String { text("menu.space.bringHere", "Move to This Window") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ProfileActions", bundle: .module)
    }
}
