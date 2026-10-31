import Foundation

/// Right sidebar strings (table RightSidebar.xcstrings).
enum RightSidebarStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "RightSidebar", bundle: .module)
    }

    static var untitledPane: String { t("rightSidebar.dock.untitledPane", "Pane") }
    static var dockEmpty: String { t("rightSidebar.dock.empty", "No docked columns on this screen. A docked column stays at the edge while the others scroll.") }
    static var undock: String { t("rightSidebar.dock.undock", "Undock") }
    static var dockFocused: String { t("rightSidebar.dock.dockFocused", "Dock Focused Column") }
    static var resize: String { t("rightSidebar.a11y.resize", "Resize right sidebar") }
    static var thisMac: String { t("rightSidebar.machines.thisMac", "This Mac") }
}
