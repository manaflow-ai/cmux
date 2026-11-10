import CmuxNextDesign
import Foundation

/// The group editor's and the group chip's strings (Resources/Localizable.xcstrings, en and ja).
/// Rows the group's right-click menu also offers use its words (Close All in Group, Ungroup, Move to
/// New Window: CmuxNextActions ObjectMenuLabels).
enum GroupEditorStrings {
    static var editor: String { String(localized: "sidebar.groupEditor.ax", defaultValue: "Edit Workspace Group", bundle: .module) }
    static var nameLabel: String { String(localized: "sidebar.groupEditor.name", defaultValue: "Group name", bundle: .module) }
    static var namePlaceholder: String { String(localized: "sidebar.groupEditor.namePlaceholder", defaultValue: "Name this group", bundle: .module) }
    static var newWorkspace: String { String(localized: "sidebar.groupEditor.newWorkspace", defaultValue: "New Workspace in Group", bundle: .module) }
    static var moveToNewWindow: String { String(localized: "sidebar.groupEditor.moveToNewWindow", defaultValue: "Move to New Window", bundle: .module) }
    static var close: String { String(localized: "sidebar.groupEditor.closeAll", defaultValue: "Close All in Group", bundle: .module) }
    static var ungroup: String { String(localized: "sidebar.groupEditor.ungroup", defaultValue: "Ungroup", bundle: .module) }
    static var delete: String { String(localized: "sidebar.groupEditor.delete", defaultValue: "Delete Group", bundle: .module) }
    static var pin: String { String(localized: "sidebar.groupEditor.pin", defaultValue: "Pin Group", bundle: .module) }
    static var unpin: String { String(localized: "sidebar.groupEditor.unpin", defaultValue: "Unpin Group", bundle: .module) }
    static var moveToTop: String { String(localized: "sidebar.groupEditor.moveToTop", defaultValue: "Move to Top", bundle: .module) }
    static var sort: String { String(localized: "sidebar.groupEditor.sort", defaultValue: "Sort", bundle: .module) }
    static var sortUndo: String { String(localized: "sidebar.groupSort.undo", defaultValue: "Sort Group", bundle: .module) }
    static var rowLimitUndo: String { String(localized: "sidebar.groupRowLimit.undo", defaultValue: "Set Chats per Project", bundle: .module) }
    static var moreActions: String { String(localized: "sidebar.groupEditor.moreActions", defaultValue: "More Group Actions…", bundle: .module) }
    static var more: String { String(localized: "sidebar.group.more", defaultValue: "Group options", bundle: .module) }
    static var collapse: String { String(localized: "sidebar.group.collapse", defaultValue: "Collapse group", bundle: .module) }
    static var expand: String { String(localized: "sidebar.group.expand", defaultValue: "Expand group", bundle: .module) }
    static var customColor: String { String(localized: "sidebar.groupColor.custom", defaultValue: "Custom color", bundle: .module) }
    static var emoji: String { String(localized: "sidebar.groupEditor.emoji", defaultValue: "Choose emoji or icon", bundle: .module) }

    /// A sort's name in the Sort row and its menu.
    static func sortTitle(_ sort: SidebarGroupSort) -> String {
        switch sort {
        case .manual: String(localized: "sidebar.groupSort.manual", defaultValue: "Manual", bundle: .module)
        case .name: String(localized: "sidebar.groupSort.name", defaultValue: "Name", bundle: .module)
        case .recent: String(localized: "sidebar.groupSort.recent", defaultValue: "Recent", bundle: .module)
        }
    }

    /// A dot's spoken name: none, or the palette color's own name (group
    /// colors are a fixed palette, not the theme's).
    static func colorName(_ color: GroupColor) -> String {
        switch color {
        case .grey: String(localized: "sidebar.groupColor.none", defaultValue: "No color", bundle: .module)
        case .blue: String(localized: "sidebar.groupColor.blue", defaultValue: "Blue", bundle: .module)
        case .red: String(localized: "sidebar.groupColor.red", defaultValue: "Red", bundle: .module)
        case .yellow: String(localized: "sidebar.groupColor.yellow", defaultValue: "Yellow", bundle: .module)
        case .green: String(localized: "sidebar.groupColor.green", defaultValue: "Green", bundle: .module)
        case .pink: String(localized: "sidebar.groupColor.pink", defaultValue: "Pink", bundle: .module)
        case .purple: String(localized: "sidebar.groupColor.purple", defaultValue: "Purple", bundle: .module)
        case .cyan: String(localized: "sidebar.groupColor.cyan", defaultValue: "Cyan", bundle: .module)
        case .orange: String(localized: "sidebar.groupColor.orange", defaultValue: "Orange", bundle: .module)
        }
    }
}
