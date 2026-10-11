import Foundation

// Group strings. Keys live in Resources/Localizable.xcstrings (en, ja).
extension Strings {
    static var colorGrey: String { String(localized: "tabs.group.color.grey", defaultValue: "Grey", bundle: .module) }
    static var colorBlue: String { String(localized: "tabs.group.color.blue", defaultValue: "Blue", bundle: .module) }
    static var colorRed: String { String(localized: "tabs.group.color.red", defaultValue: "Red", bundle: .module) }
    static var colorYellow: String { String(localized: "tabs.group.color.yellow", defaultValue: "Yellow", bundle: .module) }
    static var colorGreen: String { String(localized: "tabs.group.color.green", defaultValue: "Green", bundle: .module) }
    static var colorPink: String { String(localized: "tabs.group.color.pink", defaultValue: "Pink", bundle: .module) }
    static var colorPurple: String { String(localized: "tabs.group.color.purple", defaultValue: "Purple", bundle: .module) }
    static var colorCyan: String { String(localized: "tabs.group.color.cyan", defaultValue: "Cyan", bundle: .module) }
    static var colorOrange: String { String(localized: "tabs.group.color.orange", defaultValue: "Orange", bundle: .module) }
    static var unnamedGroup: String { String(localized: "tabs.group.unnamed", defaultValue: "Unnamed group", bundle: .module) }
    static func groupTabCount(_ count: Int) -> String { String(localized: "tabs.group.tabCount", defaultValue: "Tabs: \(count)", bundle: .module) }
    static func groupMore(_ count: Int) -> String { String(localized: "tabs.group.more", defaultValue: "+\(count) more", bundle: .module) }
    static func axGroup(_ name: String) -> String { String(localized: "tabs.group.ax.chip", defaultValue: "Tab group \(name)", bundle: .module) }
    static var axCollapsed: String { String(localized: "tabs.group.ax.collapsed", defaultValue: "Collapsed", bundle: .module) }
    static var axExpanded: String { String(localized: "tabs.group.ax.expanded", defaultValue: "Expanded", bundle: .module) }
    static var axGroupEditor: String { String(localized: "tabs.group.ax.editor", defaultValue: "Edit Tab Group", bundle: .module) }
    static var editorNamePlaceholder: String { String(localized: "tabs.group.editor.namePlaceholder", defaultValue: "Name this group", bundle: .module) }
    static var editorNewTab: String { String(localized: "tabs.group.editor.newTab", defaultValue: "New Tab in Group", bundle: .module) }
    static var editorUngroup: String { String(localized: "tabs.group.editor.ungroup", defaultValue: "Ungroup", bundle: .module) }
    static var editorClose: String { String(localized: "tabs.group.editor.close", defaultValue: "Close Group", bundle: .module) }
    static var editorMoveToNewWindow: String { String(localized: "tabs.group.editor.moveToNewWindow", defaultValue: "Move Group to New Window", bundle: .module) }
    static var editorSave: String { String(localized: "tabs.group.editor.save", defaultValue: "Pin Group", bundle: .module) }
    static var editorUnsave: String { String(localized: "tabs.group.editor.unsave", defaultValue: "Unpin Group", bundle: .module) }
    static var axSavedBar: String { String(localized: "tabs.group.savedBar.ax", defaultValue: "Saved Tab Groups", bundle: .module) }
    static var demoGroupSelected: String { String(localized: "tabs.demo.groupSelected", defaultValue: "Group Selected Tab", bundle: .module) }
    static var demoUngroupSelected: String { String(localized: "tabs.demo.ungroupSelected", defaultValue: "Ungroup Selected", bundle: .module) }
    static var demoCollapseGroup: String { String(localized: "tabs.demo.collapseGroup", defaultValue: "Toggle Collapse", bundle: .module) }
}
