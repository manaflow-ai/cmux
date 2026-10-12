// Menu-only row titles of the icon actions (cx-k9go): every object whose
// icon can be set reads "Set Icon…" and, while it shows an icon, "Remove
// Icon" in its own right-click menu, where the object is clear. The palette
// and the CLI keep the actions' own titles ("Set Workspace Icon…"), which
// name the object. Strings live in Localizable.xcstrings.

nonisolated enum IconMenuLabels {
    static var setIcon: String { String(localized: "menu.icon.set", defaultValue: "Set Icon…", bundle: .module) }
    static var removeIcon: String { String(localized: "menu.icon.remove", defaultValue: "Remove Icon", bundle: .module) }
}
