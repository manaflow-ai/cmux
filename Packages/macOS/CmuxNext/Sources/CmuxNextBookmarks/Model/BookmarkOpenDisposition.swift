public import AppKit

/// Where an opened bookmark goes (click, Cmd-click or middle-click,
/// Cmd-Shift-click). Shift-click opens a new tab, not a new window.
public enum BookmarkOpenDisposition: String, Sendable, CaseIterable {
    case currentTab
    case newTab
    case backgroundTab

    /// The disposition a click with `flags` means.
    public static func from(_ flags: NSEvent.ModifierFlags, middleButton: Bool = false) -> BookmarkOpenDisposition {
        if flags.contains(.command) || middleButton { return flags.contains(.shift) ? .newTab : .backgroundTab }
        if flags.contains(.shift) { return .newTab }
        return .currentTab
    }
}
