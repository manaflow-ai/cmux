import CmuxSettings
import Foundation

extension Array where Element == CuratedSettingEntry {
    /// Search entries for the sidebar's Jump to Unread button row
    /// (`sidebar.showJumpToUnreadButton`), appended to ``cmuxDefault(catalog:)``.
    static var sidebarJumpToUnreadEntries: [CuratedSettingEntry] {
        [
            .init(
                section: .sidebarAppearance,
                id: "show-jump-to-unread-button",
                title: String(localized: "settings.app.showJumpToUnreadButton", defaultValue: "Show Jump to Unread Button"),
                detailText: String(localized: "settings.app.showJumpToUnreadButton.subtitle", defaultValue: "Show a button above the sidebar footer that jumps to the latest unread notification while any are unread."),
                paths: ["sidebar.showJumpToUnreadButton"],
                synonyms: "sidebar.showJumpToUnreadButton jump to unread last unread latest notification button footer shortcut hide"
            ),
        ]
    }
}
