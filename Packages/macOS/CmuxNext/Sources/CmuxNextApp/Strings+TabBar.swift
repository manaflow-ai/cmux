import Foundation

extension Strings {
    /// Trailing tab-strip button tooltip: "Split Right (⌘D)".
    static func tabBarButtonToolTip(_ title: String, shortcut: String) -> String {
        String(localized: "tabbar.button.toolTip", defaultValue: "\(title) (\(shortcut))", bundle: .module)
    }

    /// The tab strip's overflow button (`PaneToolbar.moreID`): tooltip and VoiceOver label.
    static var tabBarMore: String {
        String(localized: "tabbar.more", defaultValue: "More", bundle: .module)
    }
}
