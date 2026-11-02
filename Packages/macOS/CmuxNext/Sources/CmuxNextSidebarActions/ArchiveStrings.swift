import Foundation

/// Archive titles and refusals (Resources/SidebarArchive.xcstrings): the menu rows read as the change
/// they make, and each is the undo step's name.
nonisolated enum ArchiveStrings {
    static var archiveWorkspace: String { text("archive.archiveWorkspace", "Archive Workspace") }
    static var unarchiveWorkspace: String { text("archive.unarchiveWorkspace", "Unarchive Workspace") }
    static var archiveGroup: String { text("archive.archiveGroup", "Archive Group") }
    static var unarchiveGroup: String { text("archive.unarchiveGroup", "Unarchive Group") }
    static var archiveItem: String { text("archive.archiveItem", "Archive Item") }
    static var unarchiveItem: String { text("archive.unarchiveItem", "Unarchive Item") }
    static var needsDocument: String { text("archive.refusal.needsDocument", "this sidebar cannot archive items yet") }
    static var notPlacedYet: String { text("archive.refusal.notPlacedYet", "the workspace is still being added to the sidebar") }
    static var autoArchiveRuleTitle: String { text("autoArchive.ruleTitle", "Set Group Auto-Archive") }
    static var autoArchiveBadRule: String { text("autoArchive.refusal.badRule", "auto-archive takes default, never or a number of hours") }
    static var autoArchiveNeedsItem: String { text("autoArchive.refusal.needsItem", "name an archived workspace item, or all") }
    static var noSuchItem: String { text("archive.refusal.noSuchItem", "no such sidebar item") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "SidebarArchive", bundle: .module)
    }
}
