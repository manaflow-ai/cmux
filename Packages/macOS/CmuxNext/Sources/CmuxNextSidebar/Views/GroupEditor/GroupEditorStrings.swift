import CmuxNextDesign
import Foundation

/// The group editor's and the group chip's strings (Resources/Localizable.xcstrings, en and ja).
/// Rows the group's right-click menu also offers use its words (Close All in Group, Ungroup, Move to
/// New Window: CmuxNextActions ObjectMenuLabels).
enum GroupEditorStrings {
    static var editor: String { String(localized: "sidebar.groupEditor.ax", defaultValue: "Edit Workspace Group", bundle: .localizedModule) }
    static var nameLabel: String { String(localized: "sidebar.groupEditor.name", defaultValue: "Group name", bundle: .localizedModule) }
    static var namePlaceholder: String { String(localized: "sidebar.groupEditor.namePlaceholder", defaultValue: "Name this group", bundle: .localizedModule) }
    static var newWorkspace: String { String(localized: "sidebar.groupEditor.newWorkspace", defaultValue: "New Workspace in Group", bundle: .localizedModule) }
    static var moveToNewWindow: String { String(localized: "sidebar.groupEditor.moveToNewWindow", defaultValue: "Move to New Window", bundle: .localizedModule) }
    static var close: String { String(localized: "sidebar.groupEditor.closeAll", defaultValue: "Close All in Group", bundle: .localizedModule) }
    static var ungroup: String { String(localized: "sidebar.groupEditor.ungroup", defaultValue: "Ungroup", bundle: .localizedModule) }
    static var delete: String { String(localized: "sidebar.groupEditor.delete", defaultValue: "Delete Group", bundle: .localizedModule) }
    static var pin: String { String(localized: "sidebar.groupEditor.pin", defaultValue: "Pin Group", bundle: .localizedModule) }
    static var unpin: String { String(localized: "sidebar.groupEditor.unpin", defaultValue: "Unpin Group", bundle: .localizedModule) }
    static var moveToTop: String { String(localized: "sidebar.groupEditor.moveToTop", defaultValue: "Move to Top", bundle: .localizedModule) }
    static var sort: String { String(localized: "sidebar.groupEditor.sort", defaultValue: "Sort", bundle: .localizedModule) }
    static var sortUndo: String { String(localized: "sidebar.groupSort.undo", defaultValue: "Sort Group", bundle: .localizedModule) }
    static var moreActions: String { String(localized: "sidebar.groupEditor.moreActions", defaultValue: "More Group Actions…", bundle: .localizedModule) }
    static var more: String { String(localized: "sidebar.group.more", defaultValue: "Group options", bundle: .localizedModule) }
    static var collapse: String { String(localized: "sidebar.group.collapse", defaultValue: "Collapse group", bundle: .localizedModule) }
    static var expand: String { String(localized: "sidebar.group.expand", defaultValue: "Expand group", bundle: .localizedModule) }
    static var customColor: String { String(localized: "sidebar.groupColor.custom", defaultValue: "Custom color", bundle: .localizedModule) }
    static var emoji: String { String(localized: "sidebar.groupEditor.emoji", defaultValue: "Choose emoji or icon", bundle: .localizedModule) }

    /// A sort's name in the Sort row and its menu.
    static func sortTitle(_ sort: SidebarGroupSort) -> String {
        switch sort {
        case .manual: String(localized: "sidebar.groupSort.manual", defaultValue: "Manual", bundle: .localizedModule)
        case .name: String(localized: "sidebar.groupSort.name", defaultValue: "Name", bundle: .localizedModule)
        case .recent: String(localized: "sidebar.groupSort.recent", defaultValue: "Recent", bundle: .localizedModule)
        }
    }

    /// A dot's spoken name: none, or the palette color's own name (group
    /// colors are a fixed palette, not the theme's).
    static func colorName(_ color: GroupColor) -> String {
        switch color {
        case .grey: String(localized: "sidebar.groupColor.none", defaultValue: "No color", bundle: .localizedModule)
        case .blue: String(localized: "sidebar.groupColor.blue", defaultValue: "Blue", bundle: .localizedModule)
        case .red: String(localized: "sidebar.groupColor.red", defaultValue: "Red", bundle: .localizedModule)
        case .yellow: String(localized: "sidebar.groupColor.yellow", defaultValue: "Yellow", bundle: .localizedModule)
        case .green: String(localized: "sidebar.groupColor.green", defaultValue: "Green", bundle: .localizedModule)
        case .pink: String(localized: "sidebar.groupColor.pink", defaultValue: "Pink", bundle: .localizedModule)
        case .purple: String(localized: "sidebar.groupColor.purple", defaultValue: "Purple", bundle: .localizedModule)
        case .cyan: String(localized: "sidebar.groupColor.cyan", defaultValue: "Cyan", bundle: .localizedModule)
        case .orange: String(localized: "sidebar.groupColor.orange", defaultValue: "Orange", bundle: .localizedModule)
        }
    }
}
