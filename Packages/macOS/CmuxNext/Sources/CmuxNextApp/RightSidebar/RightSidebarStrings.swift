import Foundation

/// The Dock and Machines sections' strings (table RightSidebar.xcstrings; the sidebar that held them is gone).
enum RightSidebarStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "RightSidebar", bundle: .module)
    }

    static var untitledPane: String { t("rightSidebar.dock.untitledPane", "Pane") }
    static var thisMac: String { t("rightSidebar.machines.thisMac", "This Mac") }
}
