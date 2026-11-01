import Foundation

/// Strings of the Screenshots pane (Resources/Localizable.xcstrings).
nonisolated struct ScreenshotsStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var title: String { t("screenshots.title", "Screenshots") }
    static var allSources: String { t("screenshots.sources.all", "All Sources") }
    static var filter: String { t("screenshots.filter", "Filter") }
    static var empty: String { t("screenshots.empty", "No screenshots yet. New ones show here as soon as they are saved.") }
    static var noMatches: String { t("screenshots.empty.filtered", "No matches") }
    static var systemSource: String { t("screenshots.source.system", "macOS Screenshots") }
    static var previewSource: String { t("screenshots.source.preview", "macOS Screenshot Previews") }
    static var dropFailed: String { t("screenshots.drop.failed", "Couldn’t save the dropped items") }
    static var promptTitle: String { t("screenshots.prompt.title", "Show your screenshots?") }
    static var promptBody: String {
        t("screenshots.prompt.body", "Your screenshots are saved on your Desktop or in another folder that macOS protects. cmux reads them only after you click.")
    }
    static var promptButton: String { t("screenshots.prompt.button", "Show Screenshots") }
    static var existingNeedsClick: String {
        t("screenshots.open.existing", "Screenshots is already open. It shows your screenshots only after you click Show Screenshots in it.")
    }
    static var openedInBackground: String {
        t("screenshots.open.background", "Opened Screenshots in the background. It shows your screenshots only after you click Show Screenshots in it.")
    }

    static var renameTitle: String { t("screenshots.rename.title", "Rename") }
    static var renameConfirm: String { t("screenshots.rename.confirm", "Rename") }
    static var cancel: String { t("screenshots.rename.cancel", "Cancel") }
    static var renameExists: String { t("screenshots.rename.error.exists", "An item with that name already exists.") }
    static var renameInvalid: String { t("screenshots.rename.error.invalid", "A name can’t be empty or contain “/”.") }

    static func history(of tool: String) -> String {
        String(format: t("screenshots.source.history", "%@ History"), tool)
    }

    static func unreadable(_ label: String) -> String {
        String(format: t("screenshots.source.unreadable", "Can’t read %@"), label)
    }
}
