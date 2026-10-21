import Foundation

/// The grid's own texts (Resources/Localizable.xcstrings): its menu items and label.
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

    static var gridLabel: String { t("filegrid.a11y.grid", "Files") }
}
