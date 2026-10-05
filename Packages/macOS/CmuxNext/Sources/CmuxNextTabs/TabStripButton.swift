public import Foundation

/// One button of the strip's trailing button group (split right, split
/// down, new tab, config actions). The strip draws it and sends
/// `TabStripIntent.trailingButton(id)` on click; the App decides what runs.
public struct TabStripButton: Identifiable, Hashable, Sendable {
    /// What a menu does on this button. The App builds the menu
    /// (`TabContextTarget.trailingButton`); the strip anchors it under the button.
    public enum Menu: Hashable, Sendable {
        /// No menu: a click runs the button.
        case none
        /// A click runs the button; right-click or press-and-hold opens the
        /// menu (split: right on click, both directions in the menu).
        case secondary
        /// A click opens the menu (the overflow button).
        case primary
    }

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
    public var menu: Menu

    public init(id: String, icon: Icon, toolTip: String, accessibilityLabel: String, menu: Menu = .none) {
        self.id = id
        self.icon = icon
        self.toolTip = toolTip
        self.accessibilityLabel = accessibilityLabel
        self.menu = menu
    }
}
