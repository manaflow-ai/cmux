import Foundation

/// When a pane's surface tab bar is shown.
public enum PaneTabBarVisibility: String, CaseIterable, Sendable, SettingCodable {
    /// Always show the pane tab bar, even when the pane has zero or one tab.
    case always
    /// Show the pane tab bar only when the pane has two or more tabs.
    case multipleTabs = "multiple-tabs"
}
