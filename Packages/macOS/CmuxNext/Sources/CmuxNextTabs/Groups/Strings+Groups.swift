import Foundation

// Group strings. Keys live in Resources/Localizable.xcstrings (en, ja).
extension Strings {
    static var colorGrey: String { String(localized: "tabs.group.color.grey", defaultValue: "Grey", bundle: .l10n) }
    static var colorBlue: String { String(localized: "tabs.group.color.blue", defaultValue: "Blue", bundle: .l10n) }
    static var colorRed: String { String(localized: "tabs.group.color.red", defaultValue: "Red", bundle: .l10n) }
    static var colorYellow: String { String(localized: "tabs.group.color.yellow", defaultValue: "Yellow", bundle: .l10n) }
    static var colorGreen: String { String(localized: "tabs.group.color.green", defaultValue: "Green", bundle: .l10n) }
    static var colorPink: String { String(localized: "tabs.group.color.pink", defaultValue: "Pink", bundle: .l10n) }
    static var colorPurple: String { String(localized: "tabs.group.color.purple", defaultValue: "Purple", bundle: .l10n) }
    static var colorCyan: String { String(localized: "tabs.group.color.cyan", defaultValue: "Cyan", bundle: .l10n) }
    static var colorOrange: String { String(localized: "tabs.group.color.orange", defaultValue: "Orange", bundle: .l10n) }
    static var unnamedGroup: String { String(localized: "tabs.group.unnamed", defaultValue: "Unnamed group", bundle: .l10n) }
    static func groupTabCount(_ count: Int) -> String { String(localized: "tabs.group.tabCount", defaultValue: "Tabs: \(count)", bundle: .l10n) }
    static func groupMore(_ count: Int) -> String { String(localized: "tabs.group.more", defaultValue: "+\(count) more", bundle: .l10n) }
    static func axGroup(_ name: String) -> String { String(localized: "tabs.group.ax.chip", defaultValue: "Tab group \(name)", bundle: .l10n) }
    static var axCollapsed: String { String(localized: "tabs.group.ax.collapsed", defaultValue: "Collapsed", bundle: .l10n) }
    static var axExpanded: String { String(localized: "tabs.group.ax.expanded", defaultValue: "Expanded", bundle: .l10n) }
    static var axGroupEditor: String { String(localized: "tabs.group.ax.editor", defaultValue: "Edit Tab Group", bundle: .l10n) }
    static var editorNamePlaceholder: String { String(localized: "tabs.group.editor.namePlaceholder", defaultValue: "Name this group", bundle: .l10n) }
    static var editorNewTab: String { String(localized: "tabs.group.editor.newTab", defaultValue: "New Tab in Group", bundle: .l10n) }
    static var editorUngroup: String { String(localized: "tabs.group.editor.ungroup", defaultValue: "Ungroup", bundle: .l10n) }
    static var editorCustomColor: String { String(localized: "tabs.group.editor.customColor", defaultValue: "Custom color", bundle: .l10n) }
    static var editorClose: String { String(localized: "tabs.group.editor.close", defaultValue: "Close Group", bundle: .l10n) }
    static var editorMoveToNewWindow: String { String(localized: "tabs.group.editor.moveToNewWindow", defaultValue: "Move to New Window", bundle: .l10n) }
    static var editorSave: String { String(localized: "tabs.group.editor.save", defaultValue: "Pin Group", bundle: .l10n) }
    static var editorUnsave: String { String(localized: "tabs.group.editor.unsave", defaultValue: "Unpin Group", bundle: .l10n) }
    static var axSavedBar: String { String(localized: "tabs.group.savedBar.ax", defaultValue: "Saved Tab Groups", bundle: .l10n) }
    static var demoGroupSelected: String { String(localized: "tabs.demo.groupSelected", defaultValue: "Group Selected Tab", bundle: .l10n) }
    static var demoUngroupSelected: String { String(localized: "tabs.demo.ungroupSelected", defaultValue: "Ungroup Selected", bundle: .l10n) }
    static var demoCollapseGroup: String { String(localized: "tabs.demo.collapseGroup", defaultValue: "Toggle Collapse", bundle: .l10n) }
}
