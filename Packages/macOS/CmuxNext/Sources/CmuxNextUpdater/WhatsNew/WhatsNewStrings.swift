import Foundation

/// The What's New page's own strings (Resources/Localizable.xcstrings).
/// Release text comes localized in the documents themselves.
nonisolated enum WhatsNewStrings {
    static var title: String { UpdaterStrings.text("whatsNew.title", "What's New") }
    static var tryIt: String { UpdaterStrings.text("whatsNew.tryIt", "Try It") }
    static var learnMore: String { UpdaterStrings.text("whatsNew.learnMore", "Learn More") }
    static var allNotes: String { UpdaterStrings.text("whatsNew.allNotes", "All Release Notes") }
    static var empty: String { UpdaterStrings.text("whatsNew.empty", "There are no release notes for this version yet.") }

    static func category(_ category: WhatsNewDocument.Category) -> String {
        switch category {
        case .new: UpdaterStrings.text("whatsNew.category.new", "New")
        case .improved: UpdaterStrings.text("whatsNew.category.improved", "Improved")
        case .fixed: UpdaterStrings.text("whatsNew.category.fixed", "Fixed")
        case .security: UpdaterStrings.text("whatsNew.category.security", "Security")
        }
    }

    static func audience(_ audience: WhatsNewDocument.Audience) -> String? {
        switch audience {
        case .all: nil
        case .teams: UpdaterStrings.text("whatsNew.audience.teams", "For Teams")
        case .enterprise: UpdaterStrings.text("whatsNew.audience.enterprise", "For Enterprise")
        }
    }

    static func versionTitle(_ document: WhatsNewDocument) -> String {
        switch document.channel {
        case .nightly: UpdaterStrings.format("whatsNew.version.nightly", "cmux Nightly %@", document.version)
        case .rc, .stable: UpdaterStrings.format("whatsNew.version", "cmux %@", document.version)
        }
    }
}
