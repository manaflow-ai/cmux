import Foundation

/// Strings of the widget areas and the Add Widget gallery (Resources/Localizable.xcstrings).
nonisolated enum AppWidgetStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    /// The sidebar section that holds the person's widgets.
    static var sectionTitle: String { t("widgets.section.title", "Widgets") }
    /// The menu item and section header item that turn on edit mode.
    static var edit: String { t("widgets.edit", "Edit Widgets") }
    /// Ends edit mode.
    static var done: String { t("widgets.done", "Done") }
    /// Opens the Add Widget gallery.
    static var add: String { t("widgets.add", "Add Widget…") }
    /// The minus badge and the tile menu's item.
    static var remove: String { t("widgets.remove", "Remove Widget") }
    static var small: String { t("widgets.size.small", "Small") }
    static var medium: String { t("widgets.size.medium", "Medium") }
    static var large: String { t("widgets.size.large", "Large") }
    /// Under a stale tile's dimmed scene: its render threw and cmux tries again.
    static var retrying: String { t("widgets.retrying", "Retrying") }
    /// A stale tile's tooltip: the widget's error.
    static func staleHelp(_ reason: String) -> String {
        String(format: t("widgets.stale.help", "This widget hit an error and shows its last view. %@"), reason)
    }
    /// The gallery's title.
    static var galleryTitle: String { t("widgets.gallery.title", "Add Widget") }
    /// The gallery with nothing to add.
    static var galleryEmpty: String { t("widgets.gallery.empty", "No widgets installed") }
    static var galleryEmptyHint: String { t("widgets.gallery.emptyHint", "Get widgets in the App Store.") }
    /// A gallery preview's tooltip and accessibility label: the widget and the size it adds.
    static func addSized(_ title: String, _ size: String) -> String {
        String(format: t("widgets.gallery.addSized", "Add %1$@ (%2$@)"), title, size)
    }

    static func size(_ size: AppWidgetSize) -> String {
        switch size {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }
}
