import Foundation

/// The "Done (N)", "Archived (N)" and "Show N more" rows (`SidebarLayout+DoneFold`; Resources/Localizable.xcstrings).
extension Strings {
    static func doneFold(_ count: Int) -> String {
        String(localized: "sidebar.doneFold.title", defaultValue: "Done (\(count))", bundle: .module)
    }
    static func archivedFold(_ count: Int) -> String {
        String(localized: "sidebar.archivedFold.title", defaultValue: "Archived (\(count))", bundle: .module)
    }
    /// The bottom Archive section's row (`SidebarLayout+ArchiveSection`).
    static func archiveSection(_ count: Int) -> String {
        String(localized: "sidebar.archiveSection.title", defaultValue: "Archive (\(count))", bundle: .module)
    }
    static func showMore(_ count: Int) -> String {
        String(localized: "sidebar.showMore.title", defaultValue: "Show \(count) more", bundle: .module)
    }
    static var showFewer: String { String(localized: "sidebar.showMore.fewer", defaultValue: "Show fewer", bundle: .module) }
}
