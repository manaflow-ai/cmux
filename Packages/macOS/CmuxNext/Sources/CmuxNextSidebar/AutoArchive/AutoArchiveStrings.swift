import Foundation

/// Auto-archive's toast, card, Archived page and refusal text (Resources/Localizable.xcstrings).
public nonisolated struct AutoArchiveStrings {
    public nonisolated init() {}
    static var undoTitle: String { text("autoArchive.undoTitle", "Archive Idle Workspaces") }
    static var restoreTitle: String { text("autoArchive.restoreTitle", "Restore Workspace") }
    static var cardArchive: String { text("autoArchive.card.archive", "Archive") }
    static var cardAlways: String { text("autoArchive.card.always", "Always Archive") }
    static var cardNotNow: String { text("autoArchive.card.notNow", "Not Now") }
    static var nothingIdle: String { text("autoArchive.refusal.nothingIdle", "no workspace is idle long enough to archive") }
    static var needsDocument: String { text("autoArchive.refusal.needsDocument", "this sidebar cannot archive items yet") }

    static func archived(_ count: Int) -> String {
        String(localized: "autoArchive.toast.archived", defaultValue: "Archived \(count) idle workspaces", bundle: .module)
    }

    /// "Archive 1 idle workspace?" / "Archive 2 idle workspaces?" (plural variations in the catalog).
    static func cardQuestion(_ count: Int) -> String {
        String(localized: "autoArchive.card.question", defaultValue: "Archive \(count) idle workspaces?", bundle: .module)
    }

    static func andMore(_ count: Int) -> String {
        String(format: text("autoArchive.card.more", "and %lld more"), count)
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
