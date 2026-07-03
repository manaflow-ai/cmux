#if canImport(UIKit)
import Foundation

/// Presentation metadata for icon-backed terminal accessory actions.
public extension TerminalInputAccessoryAction {
    /// VoiceOver label for icon-only accessory actions.
    var accessibilityLabel: String? {
        switch self {
        case .escape:
            return String(localized: "terminal.shortcut.name.escape", defaultValue: "Escape")
        case .tab:
            return String(localized: "terminal.shortcut.name.tab", defaultValue: "Tab")
        case .returnKey:
            return String(localized: "terminal.shortcut.name.return", defaultValue: "Return")
        case .upArrow:
            return String(localized: "terminal.shortcut.name.upArrow", defaultValue: "Up Arrow")
        case .downArrow:
            return String(localized: "terminal.shortcut.name.downArrow", defaultValue: "Down Arrow")
        case .leftArrow:
            return String(localized: "terminal.shortcut.name.leftArrow", defaultValue: "Left Arrow")
        case .rightArrow:
            return String(localized: "terminal.shortcut.name.rightArrow", defaultValue: "Right Arrow")
        case .home:
            return String(localized: "terminal.shortcut.name.home", defaultValue: "Home")
        case .end:
            return String(localized: "terminal.shortcut.name.end", defaultValue: "End")
        case .pageUp:
            return String(localized: "terminal.shortcut.name.pageUp", defaultValue: "Page Up")
        case .pageDown:
            return String(localized: "terminal.shortcut.name.pageDown", defaultValue: "Page Down")
        case .zoomOut:
            return String(localized: "terminal.input_accessory.zoom_out", defaultValue: "Zoom Out")
        case .zoomIn:
            return String(localized: "terminal.input_accessory.zoom_in", defaultValue: "Zoom In")
        case .paste:
            return String(localized: "terminal.input_accessory.paste", defaultValue: "Paste")
        case .composer:
            return String(localized: "terminal.input_accessory.composer", defaultValue: "Composer")
        default:
            return nil
        }
    }

    /// SF Symbol name for icon-only accessory actions.
    var symbolName: String? {
        switch self {
        case .escape:
            return "escape"
        case .tab:
            return "increase.indent"
        case .returnKey:
            return "return"
        case .upArrow:
            return "arrow.up"
        case .downArrow:
            return "arrow.down"
        case .leftArrow:
            return "arrow.left"
        case .rightArrow:
            return "arrow.right"
        case .home:
            return "arrow.left.to.line"
        case .end:
            return "arrow.right.to.line"
        case .pageUp:
            return "arrow.up.to.line"
        case .pageDown:
            return "arrow.down.to.line"
        case .zoomOut:
            return "minus.magnifyingglass"
        case .zoomIn:
            return "plus.magnifyingglass"
        case .paste:
            return "doc.on.clipboard"
        case .composer:
            return "square.and.pencil"
        default:
            return nil
        }
    }
}
#endif
