import Foundation

/// The "Done (N)", "Settled (N)", "Archived (N)" and "Show N more" rows (`SidebarLayout+DoneFold`; Resources/Localizable.xcstrings).
extension Strings {
    static func doneFold(_ count: Int) -> String {
        String(localized: "sidebar.doneFold.title", defaultValue: "Done (\(count))", bundle: .localizedModule)
    }
    /// Chats waiting on background work (`sidebar.workingShelf`).
    static func workingFold(_ count: Int) -> String {
        String(localized: "sidebar.workingFold.title", defaultValue: "Working (\(count))", bundle: .localizedModule)
    }

    /// Seen, finished agent chats (`sidebar.settleFinished`).
    static func settledFold(_ count: Int) -> String {
        String(localized: "sidebar.settledFold.title", defaultValue: "Settled (\(count))", bundle: .localizedModule)
    }
    static func archivedFold(_ count: Int) -> String {
        String(localized: "sidebar.archivedFold.title", defaultValue: "Archived (\(count))", bundle: .localizedModule)
    }
    static func showMore(_ count: Int) -> String {
        String(localized: "sidebar.showMore.title", defaultValue: "Show \(count) more", bundle: .localizedModule)
    }
    static var showFewer: String { String(localized: "sidebar.showMore.fewer", defaultValue: "Show fewer", bundle: .localizedModule) }
}
