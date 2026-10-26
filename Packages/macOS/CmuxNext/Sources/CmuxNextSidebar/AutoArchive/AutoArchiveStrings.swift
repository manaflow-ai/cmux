import Foundation

/// Auto-archive's toast, card, Archived page and refusal text (Resources/Localizable.xcstrings).
public nonisolated enum AutoArchiveStrings {
    static var undoTitle: String { text("autoArchive.undoTitle", "Archive Idle Workspaces") }
    static var restoreTitle: String { text("autoArchive.restoreTitle", "Restore Workspace") }
    static var cardEyebrow: String { text("autoArchive.card.eyebrow", "Tidy Up") }
    static var cardArchive: String { text("autoArchive.card.archive", "Archive") }
    static var cardNotNow: String { text("autoArchive.card.notNow", "Not Now") }
    static var nothingIdle: String { text("autoArchive.refusal.nothingIdle", "no workspace is idle long enough to archive") }
    static var needsDocument: String { text("autoArchive.refusal.needsDocument", "this sidebar cannot archive items yet") }

    static func archived(_ count: Int) -> String {
        String(format: text("autoArchive.toast.archived", "Archived %lld idle workspaces"), count)
    }

    static func cardTitle(_ count: Int) -> String {
        String(format: text("autoArchive.card.title", "%lld workspaces look idle"), count)
    }

    static func cardDetail(_ days: Int) -> String {
        String(format: text("autoArchive.card.detail", "Not used in %lld days. Archived workspaces stay in their group, dimmed, and come back when you open them."), days)
    }

    static func andMore(_ count: Int) -> String {
        String(format: text("autoArchive.card.more", "and %lld more"), count)
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
