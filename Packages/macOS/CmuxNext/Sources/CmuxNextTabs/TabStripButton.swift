public import Foundation

/// One button of the strip's trailing button group (split right, split
/// down, new tab, config actions). The strip draws it and sends
/// `TabStripIntent.trailingButton(id)` on click; the App decides what runs.
public struct TabStripButton: Identifiable, Hashable, Sendable {
    public enum Icon: Hashable, Sendable {
        /// SF Symbol name, drawn in the strip's secondary gray.
        case symbol(String)
        /// Image file, drawn as-is (template images are tinted gray).
        case file(URL)
    }

    public let id: String
    public var icon: Icon
    /// Tooltip text, e.g. "Split Right  ⌘D".
    public var toolTip: String
    /// VoiceOver label (the action title, without the shortcut).
    public var accessibilityLabel: String
    /// A click (or right-click) opens the App's menu for this button
    /// (`TabContextTarget.trailingButton`) instead of running it: the
    /// overflow button.
    public var opensMenu: Bool

    public init(id: String, icon: Icon, toolTip: String, accessibilityLabel: String, opensMenu: Bool = false) {
        self.id = id
        self.icon = icon
        self.toolTip = toolTip
        self.accessibilityLabel = accessibilityLabel
        self.opensMenu = opensMenu
    }
}
