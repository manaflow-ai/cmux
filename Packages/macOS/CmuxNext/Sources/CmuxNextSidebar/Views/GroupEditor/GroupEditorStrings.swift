import CmuxNextDesign
import Foundation

/// The group editor's and the group chip's strings (Resources/Localizable.xcstrings, en and ja).
/// Rows the group's right-click menu also offers use its words (Close All in Group, Ungroup, Move to
/// New Window: CmuxNextActions ObjectMenuLabels).
enum GroupEditorStrings {
    static var editor: String { String(localized: "sidebar.groupEditor.ax", defaultValue: "Edit Workspace Group", bundle: .l10n) }
    static var nameLabel: String { String(localized: "sidebar.groupEditor.name", defaultValue: "Group name", bundle: .l10n) }
    static var namePlaceholder: String { String(localized: "sidebar.groupEditor.namePlaceholder", defaultValue: "Name this group", bundle: .l10n) }
    static var newWorkspace: String { String(localized: "sidebar.groupEditor.newWorkspace", defaultValue: "New Workspace in Group", bundle: .l10n) }
    static var moveToNewWindow: String { String(localized: "sidebar.groupEditor.moveToNewWindow", defaultValue: "Move to New Window", bundle: .l10n) }
    static var close: String { String(localized: "sidebar.groupEditor.closeAll", defaultValue: "Close All in Group", bundle: .l10n) }
    static var ungroup: String { String(localized: "sidebar.groupEditor.ungroup", defaultValue: "Ungroup", bundle: .l10n) }
    static var delete: String { String(localized: "sidebar.groupEditor.delete", defaultValue: "Delete Group", bundle: .l10n) }
    static var pin: String { String(localized: "sidebar.groupEditor.pin", defaultValue: "Pin Group", bundle: .l10n) }
    static var unpin: String { String(localized: "sidebar.groupEditor.unpin", defaultValue: "Unpin Group", bundle: .l10n) }
    static var moveToTop: String { String(localized: "sidebar.groupEditor.moveToTop", defaultValue: "Move to Top", bundle: .l10n) }
    static var sort: String { String(localized: "sidebar.groupEditor.sort", defaultValue: "Sort", bundle: .l10n) }
    static var sortUndo: String { String(localized: "sidebar.groupSort.undo", defaultValue: "Sort Group", bundle: .l10n) }
    static var moreActions: String { String(localized: "sidebar.groupEditor.moreActions", defaultValue: "More Group Actions…", bundle: .l10n) }
    static var more: String { String(localized: "sidebar.group.more", defaultValue: "Group options", bundle: .l10n) }
    static var collapse: String { String(localized: "sidebar.group.collapse", defaultValue: "Collapse group", bundle: .l10n) }
    static var expand: String { String(localized: "sidebar.group.expand", defaultValue: "Expand group", bundle: .l10n) }
    static var customColor: String { String(localized: "sidebar.groupColor.custom", defaultValue: "Custom color", bundle: .l10n) }
    static var emoji: String { String(localized: "sidebar.groupEditor.emoji", defaultValue: "Choose emoji or icon", bundle: .l10n) }

    /// A sort's name in the Sort row and its menu.
    static func sortTitle(_ sort: SidebarGroupSort) -> String {
        switch sort {
        case .manual: String(localized: "sidebar.groupSort.manual", defaultValue: "Manual", bundle: .l10n)
        case .name: String(localized: "sidebar.groupSort.name", defaultValue: "Name", bundle: .l10n)
        case .recent: String(localized: "sidebar.groupSort.recent", defaultValue: "Recent", bundle: .l10n)
        }
    }

    /// A dot's spoken name: none, or the palette color's own name (group
    /// colors are a fixed palette, not the theme's).
    static func colorName(_ color: GroupColor) -> String {
        switch color {
        case .grey: String(localized: "sidebar.groupColor.none", defaultValue: "No color", bundle: .l10n)
        case .blue: String(localized: "sidebar.groupColor.blue", defaultValue: "Blue", bundle: .l10n)
        case .red: String(localized: "sidebar.groupColor.red", defaultValue: "Red", bundle: .l10n)
        case .yellow: String(localized: "sidebar.groupColor.yellow", defaultValue: "Yellow", bundle: .l10n)
        case .green: String(localized: "sidebar.groupColor.green", defaultValue: "Green", bundle: .l10n)
        case .pink: String(localized: "sidebar.groupColor.pink", defaultValue: "Pink", bundle: .l10n)
        case .purple: String(localized: "sidebar.groupColor.purple", defaultValue: "Purple", bundle: .l10n)
        case .cyan: String(localized: "sidebar.groupColor.cyan", defaultValue: "Cyan", bundle: .l10n)
        case .orange: String(localized: "sidebar.groupColor.orange", defaultValue: "Orange", bundle: .l10n)
        }
    }
}
