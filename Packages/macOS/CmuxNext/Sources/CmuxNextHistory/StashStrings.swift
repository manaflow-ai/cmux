import Foundation

/// Strings of the Stashed page (Resources/Localizable.xcstrings).
nonisolated enum StashStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var title: String { t("stash.title", "Stashed Tabs") }
    static var empty: String { t("stash.empty", "No stashed tabs. Right-click a browser tab or a workspace and choose Save and Close to keep it here.") }
    static var searchPlaceholder: String { t("stash.search", "Search stashed tabs") }
    static var noMatches: String { t("stash.noMatches", "No stashed tabs match.") }
    static var untitledWorkspace: String { t("stash.untitledWorkspace", "Untitled Workspace") }
    static var untitled: String { t("stash.untitled", "Untitled Group") }
    static var restoreAll: String { t("stash.restoreAll", "Restore All") }
    static var restoreInNewWorkspace: String { t("stash.restoreInNewWorkspace", "Restore in New Workspace") }
    static var restore: String { t("stash.restore", "Restore") }
    static var deleteGroup: String { t("stash.deleteGroup", "Delete Group") }
    static var delete: String { t("stash.delete", "Delete") }
    static var importFromOneTab: String { t("stash.import.button", "Import from OneTab…") }
    static var importHint: String {
        t("stash.import.hint", "In OneTab, choose Export / Import URLs, copy the text, and paste it here. Each blank-line-separated group becomes a stashed group.")
    }
    static var importAction: String { t("stash.import.action", "Import") }
    static var cancel: String { t("stash.import.cancel", "Cancel") }
    static var importNothing: String { t("stash.import.nothing", "No tabs found in the pasted text.") }
    static func imported(_ imported: Int, skipped: Int) -> String {
        t("stash.import.result", "Imported \(imported), skipped \(skipped).")
    }
    static var deletedTab: String { t("stash.deleted.tab", "Stashed tab deleted") }
    static var deletedGroup: String { t("stash.deleted.group", "Stashed group deleted") }
}
