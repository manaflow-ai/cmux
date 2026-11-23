import Foundation

/// The "Done (N)", "Settled (N)", "Archived (N)" and "Show N more" rows (`SidebarLayout+DoneFold`; Resources/Localizable.xcstrings).
extension Strings {
    static func doneFold(_ count: Int) -> String {
        String(localized: "sidebar.doneFold.title", defaultValue: "Done (\(count))", bundle: .localizedModule)
    }
    /// Sessions no person started (`sidebar.showAutomaticSessions` off).
    static func automaticFold(_ count: Int) -> String {
        String(localized: "sidebar.automaticFold.title", defaultValue: "Automatic (\(count))", bundle: .localizedModule)
    }

    /// Seen, finished agent chats (`sidebar.settleFinished`).
    static func settledFold(_ count: Int) -> String {
        String(localized: "sidebar.settledFold.title", defaultValue: "Settled (\(count))", bundle: .localizedModule)
    }
    static func archivedFold(_ count: Int) -> String {
        String(localized: "sidebar.archivedFold.title", defaultValue: "Archived (\(count))", bundle: .localizedModule)
    }
    /// The bottom Archive section's row (`SidebarLayout+ArchiveSection`).
    static func archiveSection(_ count: Int) -> String {
        String(localized: "sidebar.archiveSection.title", defaultValue: "Archive (\(count))", bundle: .localizedModule)
    }
    static func showMore(_ count: Int) -> String {
        String(localized: "sidebar.showMore.title", defaultValue: "Show \(count) more", bundle: .localizedModule)
    }
    static var showFewer: String { String(localized: "sidebar.showMore.fewer", defaultValue: "Show fewer", bundle: .localizedModule) }
}
