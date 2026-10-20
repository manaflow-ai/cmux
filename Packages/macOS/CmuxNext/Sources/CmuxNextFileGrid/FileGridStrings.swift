import Foundation

/// The grid's own texts (Resources/Localizable.xcstrings): menu items and the rename sheet.
nonisolated struct FileGridStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static func title(_ command: FileGridCommand) -> String {
        switch command {
        case .open: t("filegrid.menu.open", "Open")
        case .quickLook: t("filegrid.menu.quickLook", "Quick Look")
        case .reveal: t("filegrid.menu.reveal", "Show in Finder")
        case .copy: t("filegrid.menu.copy", "Copy")
        case .copyPath: t("filegrid.menu.copyPath", "Copy Path")
        case .rename: t("filegrid.menu.rename", "Rename…")
        case .trash: t("filegrid.menu.trash", "Move to Trash")
        }
    }

    static var renameTitle: String { t("filegrid.rename.title", "Rename") }
    static var renameConfirm: String { t("filegrid.rename.confirm", "Rename") }
    static var cancel: String { t("filegrid.rename.cancel", "Cancel") }
    static var renameExists: String { t("filegrid.rename.error.exists", "An item with that name already exists.") }
    static var renameInvalid: String { t("filegrid.rename.error.invalid", "A name can’t be empty or contain “/” or “:”.") }
    static var gridLabel: String { t("filegrid.a11y.grid", "Files") }
}
