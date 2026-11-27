import Foundation

// Group strings. Keys live in Resources/Localizable.xcstrings (en, ja).
extension Strings {
    static var colorGrey: String { String(localized: "tabs.group.color.grey", defaultValue: "Grey", bundle: .localizedModule) }
    static var colorBlue: String { String(localized: "tabs.group.color.blue", defaultValue: "Blue", bundle: .localizedModule) }
    static var colorRed: String { String(localized: "tabs.group.color.red", defaultValue: "Red", bundle: .localizedModule) }
    static var colorYellow: String { String(localized: "tabs.group.color.yellow", defaultValue: "Yellow", bundle: .localizedModule) }
    static var colorGreen: String { String(localized: "tabs.group.color.green", defaultValue: "Green", bundle: .localizedModule) }
    static var colorPink: String { String(localized: "tabs.group.color.pink", defaultValue: "Pink", bundle: .localizedModule) }
    static var colorPurple: String { String(localized: "tabs.group.color.purple", defaultValue: "Purple", bundle: .localizedModule) }
    static var colorCyan: String { String(localized: "tabs.group.color.cyan", defaultValue: "Cyan", bundle: .localizedModule) }
    static var colorOrange: String { String(localized: "tabs.group.color.orange", defaultValue: "Orange", bundle: .localizedModule) }
    static var unnamedGroup: String { String(localized: "tabs.group.unnamed", defaultValue: "Unnamed group", bundle: .localizedModule) }
    static func groupTabCount(_ count: Int) -> String { String(localized: "tabs.group.tabCount", defaultValue: "Tabs: \(count)", bundle: .localizedModule) }
    static func groupMore(_ count: Int) -> String { String(localized: "tabs.group.more", defaultValue: "+\(count) more", bundle: .localizedModule) }
    static func axGroup(_ name: String) -> String { String(localized: "tabs.group.ax.chip", defaultValue: "Tab group \(name)", bundle: .localizedModule) }
    static var axCollapsed: String { String(localized: "tabs.group.ax.collapsed", defaultValue: "Collapsed", bundle: .localizedModule) }
    static var axExpanded: String { String(localized: "tabs.group.ax.expanded", defaultValue: "Expanded", bundle: .localizedModule) }
    static var axGroupEditor: String { String(localized: "tabs.group.ax.editor", defaultValue: "Edit Tab Group", bundle: .localizedModule) }
    static var editorNamePlaceholder: String { String(localized: "tabs.group.editor.namePlaceholder", defaultValue: "Name this group", bundle: .localizedModule) }
    static var editorNewTab: String { String(localized: "tabs.group.editor.newTab", defaultValue: "New Tab in Group", bundle: .localizedModule) }
    static var editorUngroup: String { String(localized: "tabs.group.editor.ungroup", defaultValue: "Ungroup", bundle: .localizedModule) }
    static var editorCustomColor: String { String(localized: "tabs.group.editor.customColor", defaultValue: "Custom color", bundle: .localizedModule) }
    static var editorClose: String { String(localized: "tabs.group.editor.close", defaultValue: "Close Group", bundle: .localizedModule) }
    static var editorMoveToNewWindow: String { String(localized: "tabs.group.editor.moveToNewWindow", defaultValue: "Move to New Window", bundle: .localizedModule) }
    static var editorSave: String { String(localized: "tabs.group.editor.save", defaultValue: "Pin Group", bundle: .localizedModule) }
    static var editorUnsave: String { String(localized: "tabs.group.editor.unsave", defaultValue: "Unpin Group", bundle: .localizedModule) }
    static var axSavedBar: String { String(localized: "tabs.group.savedBar.ax", defaultValue: "Saved Tab Groups", bundle: .localizedModule) }
    static var demoGroupSelected: String { String(localized: "tabs.demo.groupSelected", defaultValue: "Group Selected Tab", bundle: .localizedModule) }
    static var demoUngroupSelected: String { String(localized: "tabs.demo.ungroupSelected", defaultValue: "Ungroup Selected", bundle: .localizedModule) }
    static var demoCollapseGroup: String { String(localized: "tabs.demo.collapseGroup", defaultValue: "Toggle Collapse", bundle: .localizedModule) }
}
