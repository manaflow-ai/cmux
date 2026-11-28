import Foundation

extension Strings {
    /// Trailing tab-strip button tooltip: "Split Right (⌘D)".
    static func tabBarButtonToolTip(_ title: String, shortcut: String) -> String {
        String(localized: "tabbar.button.toolTip", defaultValue: "\(title) (\(shortcut))", bundle: .module)
    }
}
