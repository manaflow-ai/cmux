import Foundation

/// Strings of the Memory Inspector (Resources/Localizable.xcstrings).
nonisolated struct ChiefMemoryStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var search: String { t("chiefMemory.search", "Search memory") }
    static var counts: String { t("chiefMemory.counts", "%1$lld messages, %2$lld summary lines") }
    static var rebuilding: String { t("chiefMemory.rebuilding", "Rebuilding %lld lines") }
    static var view: String { t("chiefMemory.view", "What the Chief reads") }
    static var results: String { t("chiefMemory.results", "Search results") }
    static var noResults: String { t("chiefMemory.results.none", "Nothing matches.") }
    static var back: String { t("chiefMemory.back", "Back") }
    static var pickLine: String { t("chiefMemory.pick", "Select a line to see what it covers.") }
    static var summaryLine: String { t("chiefMemory.summaryLine", "Summary line") }
    static var message: String { t("chiefMemory.message", "Message") }
    static var covers: String { t("chiefMemory.covers", "Lines under it") }
    static var stale: String { t("chiefMemory.stale", "Rebuilding") }
    static var edit: String { t("chiefMemory.edit", "Edit") }
    static var save: String { t("chiefMemory.save", "Save") }
    static var cancel: String { t("chiefMemory.cancel", "Cancel") }
    static var delete: String { t("chiefMemory.delete", "Delete…") }
    static var deleteTitle: String { t("chiefMemory.delete.title", "Delete this from the Chief’s memory?") }
    static var deleteMessage: String {
        t("chiefMemory.delete.message",
          "Its text becomes “(deleted by the user)” and the summaries above it are rebuilt. A backup is kept, and you can undo this.")
    }
    static var deleteConfirm: String { t("chiefMemory.delete.confirm", "Delete") }
    static var changes: String { t("chiefMemory.changes", "Changes") }
    static var noChanges: String { t("chiefMemory.changes.none", "No changes yet. A backup is written before the first one.") }
    static var undo: String { t("chiefMemory.undo", "Undo") }
    static var undone: String { t("chiefMemory.undone", "Undone") }
    static var edited: String { t("chiefMemory.edited", "Edited %@") }
    static var deleted: String { t("chiefMemory.deleted", "Deleted %@") }
    static var messageLabel: String { t("chiefMemory.label.message", "message %lld") }
    static var lineLabel: String { t("chiefMemory.label.line", "line %@") }
    static var readOnly: String { t("chiefMemory.readOnly", "This Chief’s memory can be read here but not changed. Update cmux to change it.") }
    static var unreachable: String { t("chiefMemory.unreachable", "The Chief’s memory did not answer. Start the Chief (send it a message in Home), then try again.") }
    static var malformed: String { t("chiefMemory.malformed", "The Chief answered in a way this version of cmux does not understand.") }
}
